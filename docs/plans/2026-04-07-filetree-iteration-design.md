# FileTree 迭代设计文档

日期：2026-04-07

## 调研背景

本文档基于对 **VSCode Explorer**（`src/vs/workbench/contrib/files/browser/`）和 **Zed Project Panel**（`crates/project_panel/`）两个主流开源编辑器源码的深度调研，结合 agentGui 当前文件树实现状态，梳理出可独立交付的迭代 Feature。

---

## 一、当前实现状态

### 现有能力（已稳定）

| 层 | 文件 | 关键能力 |
|---|---|---|
| 视图层 | `WorkspaceTreeOutlineView.swift` | NSOutlineView 封装，行复用，多选，内联编辑，拖放 |
| 视图层 | `WorkspaceTreeRowContent.swift` | 文件图标、文件名、Git badge（M/A/D/?），hover 背景 |
| ViewModel | `WorkspaceTreeViewModel.swift` | rootNodes、多选状态（primary + set）、搜索文本、内联编辑状态 |
| ViewModel | `WorkspacePanelLSPFooterPresenter.swift` | LSP 状态栏（与文件树无直接耦合） |
| 服务层 | `WorkspaceTreeRefreshCoordinator.swift` | FSEvents 监听 + 150ms 防抖 + 增量局部刷新（applyPartialUpdate） |
| 工具层 | `WorkspaceFileTreeOperations.swift` | 新建/重命名/删除/移动文件，路径校验 |
| 工具层 | `WorkspaceTreeDropCoordinator.swift` | 拖放安全校验（禁止拖入自身/后代） |
| 工具层 | `WorkspaceRevealService.swift` | NSWorkspace 系 Finder 打开，支持多选 |

### 当前已知限制

1. **子目录全量加载**：打开工作区时递归加载所有节点，大型仓库（数万文件）启动慢。
2. **搜索仅过滤**：`treeSearchText` 过滤不匹配项，无高亮模式（不匹配项消失，导致方向感弱）。
3. **Git badge 仅文件级**：父目录不聚合子文件的 Git 状态，难以一眼定位变更热区。
4. **无 LSP 诊断指示**：文件树无法感知 LSP 报错，需要逐个打开文件才能发现。
5. **无 Auto-fold**：`a/b/c` 这类只有一个子目录的路径占三行，信息密度低。
6. **无缩进指引线**：深层嵌套时层级关系不清晰。
7. **无 .gitignore 过滤**：隐藏文件/编译产物（`build/`、`.DS_Store`）显示在树中。
8. **键盘导航有限**：缺少 SelectParent（跳到父目录）、跳到下一个 Git 变更项、跳到下一个诊断项等。

---

## 二、调研发现：VSCode 与 Zed 的关键设计模式

### 2.1 虚拟化渲染

| 方案 | VSCode | Zed |
|---|---|---|
| 组件 | `WorkbenchCompressibleAsyncDataTree`（monaco-list 虚拟列表） | `uniform_list`（GPUI 固定行高虚拟滚动） |
| 数据模型 | 树形异步节点，展开时 `getChildren()` | 后台线程预计算扁平 `Vec<VisibleEntry>`，主线程只渲染索引 |
| 行高 | 固定 22px | 固定高度 |

**对 agentGui 的意义**：NSOutlineView 已内置虚拟滚动。真正的瓶颈是**初始化时全量递归扫描**——应改为懒加载（目录展开时才扫描子项）。

### 2.2 Auto-fold（Compact Folders）

VSCode 的 `ExplorerCompressionDelegate` 将 `a/b/c`（直链单子目录）压缩成一个可导航节点。Zed 的 `FoldedAncestors` 机制类似但更精细：支持折叠段内各部分分别作为拖放 target。

**agentGui 可行方案**：节点构建阶段将 `a/b/c` 压缩为 `FileNode(displayPath: "a/b/c", ...)` + 存储 `segments: ["a","b","c"]`，单击任意段可展开/折叠。

### 2.3 Git 状态聚合

Zed 的 `GitSummary` 在 `ChildEntriesGitIter` 中聚合所有子节点状态，目录显示一个半透明彩点。优先级：冲突 > 未追踪 > 删除 > 修改 > 暂存中新增。

### 2.4 搜索双模式

VSCode 提供 **Filter 模式**（不匹配项隐藏）和 **Highlight 模式**（不匹配项仍可见，折叠目录显示匹配数角标）。目前 agentGui 只有 Filter 模式。

### 2.5 .gitignore / 排除规则

VSCode 用三叉搜索树（TernarySearchTree）做路径匹配；Zed 字段驱动（`entry.is_ignored`、`entry.is_hidden`）。

### 2.6 键盘导航（Zed 丰富度最高）

```
SelectParent           → 跳到父目录
SelectNextGitEntry     → 跳到下一个 Git 变更文件
SelectPrevGitEntry     → 跳到上一个 Git 变更文件
SelectNextDiagnostic   → 跳到下一个有 LSP 诊断的文件
FoldDirectory          → 手动折叠 Auto-fold 展开段
UnfoldDirectory        → 手动展开 Auto-fold 折叠段
CollapseAllEntries     → 全部折叠
```

### 2.7 Sticky Scroll（Zed 特有）

`render_sticky_entries()` 将当前滚动视口顶部的祖先路径固定在列表顶部，类似代码编辑器的 sticky function 头部。

---

## 三、Feature 清单

以下按**优先级**排序，每个 Feature 可独立交付。标记 `perf`（性能）或 `ux`（可用性）。

---

### FT-P1：懒加载子目录 `[perf]`

**问题**：当前 `WorkspaceTreeSnapshotOps.buildNodes` 递归扫描全部层级，大型项目（如 Linux Kernel、大型 monorepo）会在第一次加载时卡顿数秒。

**方案**：
- `FileNode` 新增 `childrenState: .notLoaded | .loading | .loaded([FileNode])`
- `WorkspaceTreeRefreshCoordinator` 初始只扫描 1 层 + 标记目录为 `.notLoaded`
- `NSOutlineViewDelegate.outlineView(_:numberOfChildrenOfItem:)` 检查 `childrenState`，`.notLoaded` 时返回 1（占位），并触发异步扫描
- 扫描完成后 `reloadItem(_:reloadChildren:true)` 刷新该节点
- 已展开目录的子树在 FSEvent 触发时仍走现有 `applyPartialUpdate` 路径

**关键指标**：50,000 文件的工作区首次加载时间 < 200ms（仅扫描根目录 1 层）。

**涉及文件**：
- `Models/FileNode.swift` — 新增 `childrenState` 枚举
- `Utilities/WorkspaceTreeSnapshotOps.swift` — 新增 `shallowScanOne` 方法
- `Utilities/WorkspaceTreeRefreshCoordinator.swift` — 调整 `buildNodes` 策略
- `Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` — Coordinator 的 `numberOfChildren` / `child` 支持懒加载

**测试**：单测验证展开前子节点计数为 1（占位），展开后正确扫描并更新。

---

### FT-P2：后台增量排序去重 `[perf]`

**问题**：FSEvent 批量更新时（如 `git checkout` 切分支），`reloadData()` 全量重绘，卡顿明显。

**方案**（参考 Zed `par_sort_worktree_entries_with_mode`）：
- `WorkspaceTreeRefreshCoordinator` 收到 FSEvent 批次时，在 Swift Concurrency 后台任务（`Task.detached(priority: .utility)`）中对变更路径排序去重
- 合并窗口期（现有 150ms 防抖）内多次 FSEvent 累积到 `pendingPaths` set，一次性处理
- 只对变更路径的最浅公共祖先节点刷新（现有 `applyPartialUpdate` 已有基础，此处优化"多个独立路径同时变更"的场景）
- 背压：若上一次扫描任务未完成，新任务直接取消旧任务（现有 `scanTask?.cancel()` 策略保持）

**涉及文件**：
- `Utilities/WorkspaceTreeRefreshCoordinator.swift` — 批量去重 + 最浅公共祖先计算

---

### FT-U1：Auto-fold（单子目录压缩显示）`[ux]`

**问题**：`src/main/java/com/example/app/` 这类深层单子目录路径在树中占很多行，信息密度极低。

**方案**（参考 VSCode `explorer.compactFolders`）：
- `FileNode` 新增 `foldedDisplayPath: String?`（如 `"src/main/java"`）和 `foldedSegments: [String]`
- `WorkspaceTreeSnapshotOps.buildNodes` 构建阶段：检测到目录仅有一个子目录时，将路径压缩合并
- `WorkspaceTreeRowContent`：当 `foldedDisplayPath != nil` 时以 `a / b / c` 分段渲染（`/` 作为分隔符，灰色），支持点击任意段展开/折叠至该段
- `WorkspaceTreeOutlineView`：压缩节点展开时展开到最内层真实目录（而非逐层展开）
- 可关闭：`AppSettings` 新增 `compactFolders: Bool = true`（在 Workspace Preferences 中可配置）

**边界情况**：
- 根节点不压缩（与 VSCode 一致）
- 正在内联编辑的节点不压缩
- 屏幕朗读模式（`NSWorkspace.isVoiceOverEnabled`）时不压缩

**涉及文件**：
- `Models/FileNode.swift` — `foldedDisplayPath`, `foldedSegments`
- `Utilities/WorkspaceTreeSnapshotOps.swift` — 压缩逻辑
- `Views/WorkspaceTree/WorkspaceTreeRowContent.swift` — 分段渲染
- `Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` — 压缩节点展开策略

---

### FT-U2：Git 状态目录聚合徽章 `[ux]`

**问题**：父目录不显示子文件的 Git 状态聚合，折叠的目录无法判断其下是否有改动。

**方案**（参考 Zed `GitSummary` 聚合）：

优先级（高 → 低，取子树中最高优先级状态）：
```
conflict(!) > untracked(U) > deleted(D) > unstaged-modified(M) > staged-modified(M̃) > added(A)
```

- `GitChangeStatus` 扩展为 `GitSummary`，增加 `directoryAggregate` 案例
- `WorkspaceTreeViewModel` 的 `gitChangeProvider` 闭包：对目录节点，遍历 ViewModel 持有的 `gitChanges` set，找出子树中最高优先级状态
- 目录用**彩点**（`●`，半透明）表示聚合状态，而非字母 badge，与文件的字母 badge 形成视觉区分
- 目录已展开且所有子状态可见时，不重复显示聚合点（降低视觉噪音）

**涉及文件**：
- `Models/GitChangeStatus.swift` — `GitSummary` 结构
- `ViewModels/WorkspaceTreeViewModel.swift` — `gitChangeProvider` 聚合逻辑
- `Views/WorkspaceTree/WorkspaceTreeRowContent.swift` — 目录 badge 渲染（彩点 vs 字母）

---

### FT-U3：LSP 诊断徽章集成 `[ux]`

**问题**：文件有编译错误/警告时，只能打开文件才能发现，无法在文件树层面感知。

**方案**（参考 Zed `entry_diagnostic_aware_icon_decoration_and_color`）：

- 在 `WorkspaceTreeViewModel` 注入 `DiagnosticSummaryProvider` 协议（由现有 `LSPWorkspaceService` 实现）
- `FileNode` 关联 `diagnosticSeverity: DiagnosticSeverity?`（`.error` / `.warning` / `.hint`）
- `WorkspaceTreeRowContent`：文件图标右下角显示角标（红色 `×` = error，黄色 `△` = warning）
- 目录聚合：展示子树中最严重的诊断级别，优先级 error > warning > hint
- 文件图标**主色**：有 error 的文件图标轻度变红（`foregroundStyle(diagnosticIconColor)`），与 Zed 风格一致
- 诊断更新来自 `LSPWorkspaceService.onDiagnosticsChanged`，走现有 `@Observable` 链路驱动 UI 更新

**涉及文件**：
- `Services/DiagnosticSummaryProvider.swift` — 新接口
- `ViewModels/WorkspaceTreeViewModel.swift` — 注入 `diagnosticSummaryProvider`
- `Views/WorkspaceTree/WorkspaceTreeRowContent.swift` — 诊断角标渲染

---

### FT-U4：树内搜索高亮模式 `[ux]`

**问题**：当前搜索直接过滤不匹配项，树结构发生坍塌，用户失去空间感。

**方案**（参考 VSCode `ExplorerFindProvider` 的双模式）：

新增 `WorkspaceSearchMode` 枚举：
```swift
enum WorkspaceSearchMode {
    case filter    // 当前行为：隐藏不匹配项
    case highlight // 新行为：不匹配项保留灰显，匹配项高亮
}
```

- 搜索栏右侧新增切换按钮（`line.3.horizontal.decrease.circle` / `magnifyingglass`）
- Highlight 模式：
  - `filteredNodes()` 不删除任何节点，改为在节点上附加 `highlightRanges: [Range<String.Index>]?`
  - 不匹配的节点 `opacity(0.4)` 显示
  - `WorkspaceTreeRowContent` 对文件名使用 `AttributedString` 加黄色高亮
  - 折叠目录角标：显示 `(N)` 表示子树内有 N 个匹配（参考 VSCode 的 `ExplorerFindHighlightTree`）
- 搜索框 Escape：清空输入并回到 filter 模式（现有行为不变）
- `Return`（唯一结果时）：打开文件（现有 `openSingleSearchResultIfPossible` 扩展至 highlight 模式）

**涉及文件**：
- `ViewModels/WorkspaceTreeViewModel.swift` — `searchMode`, `highlightedNodes()`
- `Views/WorkspacePanelView.swift` — 搜索模式切换按钮
- `Views/WorkspaceTree/WorkspaceTreeRowContent.swift` — `AttributedString` 高亮渲染
- `Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` — `opacity` 驱动

---

### FT-U5：键盘导航增强 `[ux]`

**问题**：当前键盘导航仅支持基础 NSOutlineView 默认行为（↑↓ 移动），缺少高效跳转。

**方案**（参考 Zed 动作系统）：

在 `WorkspaceTreeKeyboardShortcut.swift` 新增以下动作：

| 快捷键 | 动作 | 说明 |
|---|---|---|
| `⌘↑` | SelectParent | 选中当前节点的父目录 |
| `⌥G` / `⌥⇧G` | SelectNextGitEntry / SelectPrevGitEntry | 在 Git 变更文件间跳转 |
| `⌥D` / `⌥⇧D` | SelectNextDiagnostic / SelectPrevDiagnostic | 在有 LSP 诊断的文件间跳转（需 FT-U3）|
| `⌘⇧E` | CollapseAllEntries | 折叠全部到根目录 |
| `⌥Click`目录 | ExpandAllChildren | 递归展开该目录下所有子目录（与 VSCode `Alt+Click` 一致）|

- `SelectParent` 通过 `findParent(in: rootNodes, target: selectedID)` 实现
- Git 跳转通过对 `gitChanges` 排序后二分查找当前位置再向前/后遍历实现
- 诊断跳转依赖 FT-U3 的 `DiagnosticSummaryProvider`

**涉及文件**：
- `Views/WorkspaceTree/WorkspaceTreeKeyboardShortcut.swift`
- `Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` — `handleKeyboardAction` 扩展
- `ViewModels/WorkspaceTreeViewModel.swift` — SelectParent / 跳转逻辑

---

### FT-U6：缩进指引线 `[ux]`

**问题**：深层嵌套目录（> 3 层）时父子关系不直观，尤其在分辨率低的屏幕上。

**方案**：
- `WorkspaceTreeOutlineView` 重写 `draw(_:)` 或使用自定义 `NSTableRowView`，在每行 X 轴 `depth * indentationPerLevel` 处绘制 1px 竖线
- 颜色：`NSColor.separatorColor.withAlphaComponent(0.35)`，浅色/深色模式自适应
- 悬停高亮：鼠标悬停行时，其所在层级的指引线加深（参考 VSCode indent guide hover effect）
- 性能：指引线在 `NSTableRowView.drawBackground(in:)` 中绘制，不增加视图层级

**涉及文件**：
- `Views/WorkspaceTree/WorkspaceTreeOutlineView.swift` — `WorkspaceTreeTableRowView.drawBackground` 扩展
- 新增 `Views/WorkspaceTree/TreeIndentGuideConfiguration.swift`（颜色、宽度常量）

---

### FT-U7：`.gitignore` 文件排除 `[ux]`

**问题**：`build/`、`DerivedData/`、`.DS_Store`、`node_modules/` 等出现在文件树中，噪音极大。

**方案**（参考 VSCode `FilesFilter` + `IgnoreFile`）：

**两阶段过滤**：
1. **硬编码排除**（默认开启，不可关闭）：`.git/`、`.DS_Store`、`Thumbs.db`
2. **`.gitignore` 解析**（默认开启，可在工作区偏好中关闭）：
   - 新增 `GitIgnoreParser`（用正则 + 通配符转换，不依赖外部库）
   - `WorkspaceTreeSnapshotOps` 在构建节点时调用 `GitIgnoreParser.isIgnored(path: relPath, root: rootURL)`
   - 解析 root`.gitignore`、子目录 `.gitignore`（深度优先继承规则）
   - `.gitignore` 文件本身变化时（FSEvent）触发全量刷新

**已在编辑器中打开的文件强制可见**（与 VSCode 一致），避免项目文件被误排除后找不到。

**涉及文件**：
- `Utilities/GitIgnoreParser.swift` — 新增
- `Utilities/WorkspaceTreeSnapshotOps.swift` — 集成过滤器
- `Models/WorkspacePreferences.swift` — `respectGitignore: Bool = true`

---

### FT-U8：Sticky 祖先路径面包屑 `[ux]`

**问题**：滚动深层目录时，失去对"当前在哪个目录下"的感知。

**方案**（参考 Zed `render_sticky_entries`）：
- `WorkspacePanelView` 的文件树区域顶部追加一个 overlay 层 `WorkspaceTreeStickyBreadcrumb`
- 随 `NSOutlineView` 的 `enclosingScrollView.contentView.bounds.origin.y` 变化，计算当前视口顶部可见行的所有祖先节点
- 以 `a > b > c` 形式横向显示（每件可点击，点击后滚动至该目录）
- 样式：`UltraThickMaterial` 毛玻璃背景，高度 22px，字号 11pt
- 根目录无祖先时不显示（隐藏该 overlay）
- 仅单根工作区时显示，多根切换时根据滚动位置自动切换 root label

**涉及文件**：
- `Views/WorkspaceTree/WorkspaceTreeStickyBreadcrumb.swift` — 新增
- `Views/WorkspacePanelView.swift` — overlay 层挂载 + scroll offset 绑定

---

## 四、优先级与交付顺序建议

| 优先级 | Feature | 理由 |
|---|---|---|
| P0 | **FT-U7**：.gitignore 排除 | 高频痛点，噪音大，用户感知最强 |
| P0 | **FT-U2**：Git 状态目录聚合 | 与已完成的 Git 工作台形成联动闭环 |
| P1 | **FT-P1**：懒加载子目录 | 大型项目必需，影响启动体验 |
| P1 | **FT-U1**：Auto-fold | 信息密度提升，尤其对 Java/Go/Rust 项目 |
| P1 | **FT-U6**：缩进指引线 | 实现简单，视觉改善明显 |
| P2 | **FT-U4**：树内搜索高亮模式 | 搜索体验提升明显，实现中等复杂度 |
| P2 | **FT-U5**：键盘导航增强 | 重度键盘用户必需，但覆盖面较窄 |
| P2 | **FT-U3**：LSP 诊断徽章 | 依赖 LSP 成熟度，需等 LSP 稳定 |
| P3 | **FT-P2**：后台增量排序去重 | 在 P1 完成后评估是否仍是瓶颈 |
| P3 | **FT-U8**：Sticky 面包屑 | 工程量偏大，收益依赖树深度 |

---

## 五、关键设计约束

1. **不引入新依赖**：保持现有 Swift 6 + AppKit + Foundation 技术栈，不引入 C/C++ 库（如 libgit2 直接 used）。
2. **向后兼容 FSEvent 链路**：新功能不破坏现有 `WorkspaceTreeRefreshCoordinator` 的 FSEvent → debounce → applyPartialUpdate 链路。
3. **测试优先**：每个 Feature 必须有对应的 `agentGuiTests/` 单元测试（逻辑层）；UI 层变化用现有 UI Test 框架验证。
4. **@MainActor 约束**：所有 ViewModel 操作保持在 `@MainActor`，后台计算通过 `Task.detached` + `MainActor.run` 回传，不直接跨 Actor 访问共享状态。
5. **可选功能开关**：Auto-fold、gitignore 排除默认开启，用 `AppSettings` / `WorkspacePreferences` 可关闭，避免强制改变用户习惯。

---

## 附录：调研来源

- VSCode `explorerView.ts`：`WorkbenchCompressibleAsyncDataTree`、`ExplorerFindProvider`、`FilesFilter`
- VSCode `explorerModel.ts`：`ExplorerItem`、`ExplorerCompressionDelegate`
- VSCode `explorerViewer.ts`：`FileDragAndDrop`、`CompressedNavigationController`
- Zed `project_panel.rs`：`VisibleEntriesForWorktree`（扁平预计算）、`FoldedAncestors`、`GitSummary`、`render_sticky_entries`、`DraggedSelection`、`hover_expand_task`
