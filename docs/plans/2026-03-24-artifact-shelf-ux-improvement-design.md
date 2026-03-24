# ArtifactShelf UX 改进技术设计

**日期：** 2026-03-24  
**状态：** 草稿 — 待审阅  
**范围：** `ArtifactShelfView` · `AgentExecutionProjection` · 相关 Presentation 数据结构

---

## 一、背景与问题陈述

当前 `ArtifactShelfView`（消息交付结果架）存在三项体验缺陷：

| # | 问题 | 当前行为 | 期望行为 |
|---|------|---------|---------|
| P1 | **类型无区分** | 文件、文件夹、URL 链接统一显示 `doc` 图标 | 本地文件、本地文件夹、Web URL 有不同图标与色调 |
| P2 | **无交互能力** | Chip / 链接点击无响应 | 点击即打开：Markdown / 文本文件 → 应用内置编辑器；其他本地文件 → 系统默认应用；文件夹 → Finder；URL → 浏览器 |
| P3 | **命令摘要无折叠** | 命令摘要行全量展开，条目多时占用大量垂直空间 | 默认折叠，仅展示前 3 行；超出时显示展开按钮 |

---

## 二、架构分析

### 现状数据流

```
ToolCall (SwiftData)  →  AgentExecutionProjection.makeArtifacts()
                       →  ArtifactShelfPresentation
                              ├─ changedFiles:  [ArtifactChipPresentation]   (edit)
                              ├─ referencedFiles: [ArtifactChipPresentation] (read/search/fetch)
                              ├─ citations:      [ArtifactChipPresentation]  (空)
                              ├─ commandSummaries: [ArtifactSummaryLine]     (execute)
                              └─ testSummaries:    [ArtifactSummaryLine]     (空)
```

`ArtifactChipPresentation` 目前仅携带 `displayName` + `path` 字符串，视图层使用硬编码 `"doc"` 图标，无点击行为。

### 层级职责

| 层 | 职责 |
|----|------|
| `AgentExecutionProjection` | 纯数据映射（nonisolated），负责从 ToolCall 构造 Presentation 结构体 |
| `ArtifactShelfPresentation` | 不可变值类型，仅描述"展示什么"，不持有行为 |
| `ArtifactShelfView` | SwiftUI 视图，消费 Presentation 渲染 UI，持有折叠状态等临时 View-State |

---

## 三、设计方案

### 3.1 新增 ArtifactResourceKind 枚举

**位置：** `agentGui/Models/Enums.swift`（与其他 UI 枚举共存）

```swift
/// 交付结果资源的具体类型，决定图标、色调和点击行为。
enum ArtifactResourceKind: Equatable {
    /// 本地可验证的普通文件
    case localFile(URL)
    /// 本地可验证的目录（文件夹）
    case localFolder(URL)
    /// HTTP/HTTPS 网页链接
    case webURL(URL)
    /// 无法解析为具体类型的资源（降级显示，不可点击）
    case unknown(String)
}

extension ArtifactResourceKind {
    var systemImage: String {
        switch self {
        case .localFile:   return "doc.fill"
        case .localFolder: return "folder.fill"
        case .webURL:      return "link"
        case .unknown:     return "questionmark.square"
        }
    }

    /// Returns the URL to open, or nil if not openable.
    var openableURL: URL? {
        switch self {
        case .localFile(let url), .localFolder(let url), .webURL(let url): return url
        case .unknown: return nil
        }
    }
}
```

**设计原则：**  
- 枚举带关联 URL，类型信息与可操作数据绑定，避免视图层再做字符串解析。  
- `unknown` 兜底，处理旧数据或格式异常情况，视图层统一降级而不崩溃。

---

### 3.2 扩展 ArtifactChipPresentation

**位置：** `agentGui/ViewModels/AgentExecutionProjection.swift`

```swift
struct ArtifactChipPresentation: Equatable, Identifiable {
    let id: String
    let displayName: String
    let path: String            // 保留用于 tooltip / 辅助功能
    let kind: ArtifactResourceKind   // 新增
}
```

**向后兼容：** 仅在 Presentation 层新增字段，`ArtifactShelfPresentation` 结构体不变，SwiftData 模型层零改动。

---

### 3.3 AgentExecutionProjection — 分类逻辑

**位置：** `makeArtifactChips(from:)` — 已是 `nonisolated` 纯函数，扩展安全。

```swift
nonisolated private static func classifyKind(for rawPath: String) -> ArtifactResourceKind {
    // 1. Web URL
    if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://"),
       let url = URL(string: rawPath) {
        return .webURL(url)
    }
    // 2. 本地路径
    let url = URL(fileURLWithPath: rawPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory) {
        return isDirectory.boolValue ? .localFolder(url) : .localFile(url)
    }
    // 3. 路径不存在但形如目录（结尾 /，或无扩展名的路径）
    if rawPath.hasSuffix("/") {
        return .localFolder(url)
    }
    // 4. 降级
    return .localFile(url)   // 对文件路径乐观推断，保留可点击能力
}
```

**注意事项：**
- `FileManager.fileExists` 在 `nonisolated` 上下文（后台线程）调用是安全的。  
- 对于不存在但推断为文件的路径，乐观构造 `localFile`，NSWorkspace 会提示"找不到文件"，比静默无响应更好。
- `fetch` 类 ToolCall 的路径可能是 URL 字符串，此逻辑已覆盖。

---

### 3.4 ArtifactSummaryLine — 命令输出字段（可选扩展）

当前 `ArtifactSummaryLine` 只有 `text`。为支持未来展开后显示命令输出，提前设计扩展字段（本次暂不实现，仅预留接口）：

```swift
struct ArtifactSummaryLine: Equatable, Identifiable {
    let id: String
    let text: String
    // 预留：命令输出摘要（未来可在展开时显示）
    // let outputSummary: String?
    // let exitCode: Int?
}
```

> 当前不添加字段，避免无谓改动；待实际需求落地时再扩展。

---

### 3.5 ArtifactShelfView — 三项视图改进

#### 3.5.1 `WorkspaceState` 注入

`ArtifactShelfView` 需通过 `@Environment` 获取 `WorkspaceState`，用于在内部编辑器打开文本文件：

```swift
struct ArtifactShelfView: View {
    let presentation: ArtifactShelfPresentation
    @Environment(WorkspaceState.self) private var workspaceState  // 新增
    ...
}
```

`WorkspaceState` 通过应用根部 `agentGuiApp.swift` 已注入 Environment 树，无需额外配置。

---

#### 3.5.2 打开分发策略（Open Dispatch）

不同资源类型的打开行为各异，将分发逻辑集中在 `ArtifactShelfView` 的私有方法中，**不污染** `ArtifactResourceKind`（它是无行为的纯数据类型）：

```swift
// 应用内置编辑器支持的文本格式
private let appEditableExtensions: Set<String> = [
    "md", "markdown",
    "txt", "text",
    "swift", "py", "js", "ts", "jsx", "tsx",
    "json", "yaml", "yml", "toml", "xml",
    "sh", "bash", "zsh",
    "css", "html", "htm",
    "gitignore", "env",
]

private func open(_ kind: ArtifactResourceKind) {
    switch kind {
    case .localFile(let url):
        // Markdown / 文本类 → 内置编辑器
        if appEditableExtensions.contains(url.pathExtension.lowercased())
            || url.pathExtension.isEmpty  // 无扩展名（dotfiles、脚本等）也走内置编辑器
        {
            workspaceState.selectedFile = url
        } else {
            // 二进制文件（图片、PDF 等）→ 系统默认应用
            NSWorkspace.shared.open(url)
        }
    case .localFolder(let url):
        // 文件夹 → Finder
        NSWorkspace.shared.open(url)
    case .webURL(let url):
        // Web 链接 → 系统默认浏览器
        NSWorkspace.shared.open(url)
    case .unknown:
        break  // 不可点击，按钮已 disabled
    }
}
```

**设计原则：**
- 分发逻辑完全在 View 层，`ArtifactResourceKind` 保持纯数据类型。
- `appEditableExtensions` 是私有集合，未来扩展只改这一处。
- 无扩展名文件乐观走内置编辑器（常见于 dotfiles、脚本等纯文本文件）。

---

#### 3.5.3 文件/文件夹/链接 Chip 区分与点击

将 `artifactChip(_:tint:)` 改为 `Button`，使用 `kind.systemImage` 替换硬编码 `"doc"`，点击调用上面的 `open(_:)` 分发方法：

```swift
private func artifactChip(_ item: ArtifactChipPresentation, tint: Color) -> some View {
    Button {
        open(item.kind)
    } label: {
        HStack(spacing: 5) {
            Image(systemName: item.kind.systemImage)
                .font(.caption2)
            Text(item.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(item.kind.openableURL != nil ? tint : tint.opacity(0.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
    .buttonStyle(.plain)
    .disabled(item.kind.openableURL == nil)
    .help(item.path)
    .cursor(.pointingHand)   // 自定义 cursor modifier（见 3.5.5）
}
```

**色调细化：**  
- 文件：`.orange`（变更）/ `.blue`（引用）—— 延续现有色彩语义  
- 文件夹：在现有 tint 基础上稍微加深（视觉上比文件更"重"）  
- URL：使用 `.accentColor` 表示外部链接——与应用内导航链接一致

> 注：色调决策由调用方 `artifactChipSection(title:iconName:items:tint:)` 传入，视图层不感知类型，**保持单一职责**。但图标由 `kind.systemImage` 决定，与 tint 解耦。

#### 3.5.4 命令摘要折叠

提取独立的 `CollapsibleSummarySection` 子视图，封装折叠状态：

```swift
private struct CollapsibleSummarySection: View {
    let title: String
    let iconName: String
    let items: [ArtifactSummaryLine]
    let tint: Color
    private static let defaultVisibleCount = 3

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：右侧展开/收起按钮
            HStack {
                sectionHeader(title: title, iconName: iconName, tint: tint)
                Spacer()
                if items.count > Self.defaultVisibleCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "收起" : "展开全部 \(items.count) 条")
                                .font(.caption2)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 内容区
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visibleItems) { item in
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)          // 单条最多 3 行防溢出
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var visibleItems: [ArtifactSummaryLine] {
        isExpanded ? items : Array(items.prefix(Self.defaultVisibleCount))
    }

    private func sectionHeader(title: String, iconName: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
```

**设计要点：**
- `@State private var isExpanded = false` 持有在视图内部，不污染 Presentation 层（UI 临时状态不应下沉到数据模型）。
- `defaultVisibleCount = 3` 为静态常量，便于后续调整。
- 展开/收起动画 `.easeInOut(duration: 0.2)` 轻量，不妨碍内容消费。
- `items.count > defaultVisibleCount` 时才渲染展开按钮，保持简洁。

#### 3.5.5 鼠标指针（macOS Hover Cursor）

macOS 上 `Button` 默认不改变光标，需自定义 modifier：

```swift
// 位置：agentGui/Utilities/ 或 ArtifactShelfView.swift 文件底部私有扩展
extension View {
    @ViewBuilder
    func cursor(_ cursor: NSCursor) -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active: cursor.push()
            case .ended:  NSCursor.pop()
            }
        }
    }
}
```

> 若项目已有 `cursor` modifier 封装，复用即可；不引入重复。

---

## 四、文件改动清单

| 文件 | 改动类型 | 说明 |
|------|---------|------|
| `agentGui/Models/Enums.swift` | **修改** | 新增 `ArtifactResourceKind` 枚举 |
| `agentGui/ViewModels/AgentExecutionProjection.swift` | **修改** | `ArtifactChipPresentation` 增加 `kind` 字段；`makeArtifactChips(from:)` 调用 `classifyKind`；新增 `classifyKind(for:)` 静态函数 |
| `agentGui/Views/ArtifactShelfView.swift` | **修改** | 注入 `@Environment(WorkspaceState.self)`；新增 `open(_:)` 分发方法和 `appEditableExtensions`；`artifactChip` 改为 Button 调用 `open(_:)`，图标换为 `kind.systemImage`；将 `artifactSummarySection` 替换为 `CollapsibleSummarySection` 子视图 |
| `agentGui/Utilities/` (已有文件) | **修改** | 检查是否已有 `cursor` modifier，若无则添加 |

**总计：修改 3–4 个文件，新增 0 个文件。**

---

## 五、边界情况与防御策略

| 场景 | 处理方式 |
|------|---------|
| Markdown 文件路径不存在（已删除或 Agent 幻觉） | 乐观构造 `localFile`；点击后 `WorkspaceState.selectedFile = url`，内置编辑器的空状态或错误提示兜底处理 |
| 非文本类本地文件（图片、PDF 等） | `appEditableExtensions` 不包含其扩展名 → 走 `NSWorkspace.shared.open(url)` |
| 文件路径不存在且非文本类 | `NSWorkspace.shared.open(url)` 在文件不存在时弹出 Finder 提示，行为符合 macOS 惯例 |
| URL 格式异常（无 scheme 等） | `classifyKind` 降级为 `unknown`，chip 显示问号图标且不可点击 |
| `referencedFiles` 中混有 URL 和文件路径 | `classifyKind` 统一处理，无需调用方区分 |
| `.md` 文件但 `WorkspaceState` 注入缺失 | `@Environment` 注入链完整（从 `agentGuiApp.swift` 下传），不存在缺失风险 |
| 命令摘要 ≤ 3 条 | 不渲染展开按钮，布局等同现状 |
| 命令摘要为空 | `CollapsibleSummarySection` 父视图已有 `if !items.isEmpty` 守卫，无影响 |
| 并发/线程安全 | `classifyKind` 和 `makeArtifactChips` 均为 `nonisolated` 纯函数，`FileManager` 调用无线程问题；`open(_:)` 和 `workspaceState.selectedFile` 赋值在 `@MainActor` 视图上下文执行，安全 |

---

## 六、可扩展性考量

| 待扩展能力 | 当前设计预留点 |
|-----------|--------------|
| 命令输出展开查看 | `ArtifactSummaryLine` 保留 `outputSummary` 注释字段，未来添加无需重构视图结构 |
| 引用（citations）支持 | `ArtifactChipPresentation.kind` 兼容 URL，直接复用 |
| 更多资源类型（图片、PDF 等） | `ArtifactResourceKind` 枚举可安全新增 case，视图通过 `systemImage` 计算属性自动适配 |
| 扩展内置编辑器支持格式 | 只需修改 `appEditableExtensions` 集合，无需改动任何其他逻辑 |
| "在 Finder 中显示"而非直接打开 | `localFile` 分支可新增右键菜单（`.contextMenu`）提供"在 Finder 中显示"选项，`open(_:)` 逻辑无需改动 |
| 深色/浅色模式下链接色适配 | `tint: .accentColor` 自动跟随系统，无需额外处理 |

---

## 七、测试策略

| 测试点 | 类型 | 位置建议 |
|--------|------|---------|
| `classifyKind` 正确区分 http URL / 本地文件 / 本地文件夹 | 单元测试 | `agentGuiTests/ArtifactShelfTests.swift`（新增） |
| `makeArtifactChips` 对 fetch ToolCall 生成 `.webURL` kind | 单元测试 | 同上 |
| `.md` 文件 chip 点击调用 `workspaceState.selectedFile = url` | 单元测试（注入 mock `WorkspaceState`） | 同上 |
| `.png` / `.pdf` 文件 chip 点击走 `NSWorkspace`，不改 `selectedFile` | 单元测试 | 同上 |
| `CollapsibleSummarySection` 初始折叠状态显示 ≤ 3 条 | 快照 / UI 测试 | 同上 |
| `CollapsibleSummarySection` 展开后显示全部 | UI 测试 | 同上 |

---

## 八、实施顺序建议

1. **Step 1** — 在 `Enums.swift` 添加 `ArtifactResourceKind`，编译通过
2. **Step 2** — 在 `AgentExecutionProjection.swift` 扩展 `ArtifactChipPresentation` 并实现 `classifyKind`；更新 `makeArtifactChips`；修复所有编译错误
3. **Step 3** — 更新 `ArtifactShelfView`：注入 `WorkspaceState`；新增 `appEditableExtensions` 和 `open(_:)` 分发方法；`artifactChip` 改为 Button 调用 `open(_:)`，图标使用 `kind.systemImage`
4. **Step 4** — 提取 `CollapsibleSummarySection`，替换 `artifactSummarySection`（命令摘要折叠）
5. **Step 5** — 添加 `cursor` modifier（如无已有实现）
6. **Step 6** — 编写单元测试
