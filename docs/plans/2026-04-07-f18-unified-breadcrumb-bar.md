# F18 统一面包屑栏 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `FilePathBreadcrumbBar`（文件路径节点）和 `CodeEditorSymbolBreadcrumbBar`（LSP symbol 节点）合并为一个新组件 `UnifiedEditorBreadcrumbBar`，在同一横向滚动行中按 `文件路径 › 符号层级` 顺序显示所有导航节点，消除两排条之间的双 `Divider` 隔断。

**Architecture:**
- 新建 `UnifiedEditorBreadcrumbBar<TrailingContent: View>`，接收 `fileItems: [BreadcrumbNavigationItem]` + `symbolPath: [CodeEditorSymbolPathNode]`，在 **单行** `ScrollView` 中统一渲染，文件节点在左、符号节点在右。  
- `CodeEditorView` 删除 `isSymbolBreadcrumbVisible` / `onSymbolNavigate` 参数和本地 `CodeEditorSymbolBreadcrumbBar` 渲染块，改为新增 `onSymbolPathChange` 回调，在光标移动时上报当前符号路径。  
- `FileEditorView` 维护 `@State var currentSymbolPath`，把 `FilePathBreadcrumbBar` + 相关 `Divider` 替换为 `UnifiedEditorBreadcrumbBar`，同时保留右侧 Trailing 按钮区域不变。

**Tech Stack:** Swift 6, SwiftUI (macOS), 现有模型 `BreadcrumbNavigationItem`、`CodeEditorSymbolPathNode`、`CodeEditorSymbolSiblingItem`、`CodeEditorRevealRequest`，现有静态函数 `CodeEditorViewModel.symbolKindIconName(for:)`。

**调研参考 — VSCode `breadcrumbsControl.ts`:**
- VSCode 使用单个 `BreadcrumbsWidget`，`BreadcrumbsModel.getElements()` 把文件路径 `FileElement` 和 LSP outline `OutlineElement2` 合并成统一数组，按顺序渲染为 `FileItem` / `OutlineItem`。
- 文件节点点击弹出 `BreadcrumbsFilePicker`，符号节点点击弹出 `BreadcrumbsOutlinePicker`，两者在同一个 picker framework 下。
- **本项目的 SwiftUI 等效**：文件节点保留 `onSelectFile` 导航行为；符号节点保留 `Menu`（siblings 下拉）或单 `Button`；Picker 弹窗暂不引入（YAGNI），与 VSCode 对齐的核心点是**同一行渲染**。

---

## 现状梳理

| 组件 | 文件 | 用途 | 层级 |
|------|------|------|------|
| `FilePathBreadcrumbBar` | `Views/Navigation/FilePathBreadcrumbBar.swift` | 文件路径节点 + TrailingContent 按钮区 | `FileEditorView` 顶层 |
| `CodeEditorSymbolBreadcrumbBar` | `Views/CodeEditor/CodeEditorSymbolBreadcrumbBar.swift` | LSP symbol 路径节点 | `CodeEditorView` 内部 |

被调用处：
- `FileEditorView.swift:149` — 使用 `FilePathBreadcrumbBar`
- `CodeEditorView.swift:97` — 在 `if isSymbolBreadcrumbVisible` block 内使用 `CodeEditorSymbolBreadcrumbBar`

`symbolBreadcrumbPath` 由 `document.selectedRange` 驱动（cursor 位置）：
```swift
// CodeEditorView.swift:174
private var symbolBreadcrumbPath: [CodeEditorSymbolPathNode] {
    let line1 = document.location(ofUTF16Offset: document.selectedRange.location).line
    let line0 = max(0, line1 - 1)
    return CodeEditorViewModel.symbolBreadcrumbNodes(for: line0, in: documentSymbols, fileURL: fileURL)
}
```

---

## Task 1：新建 `UnifiedEditorBreadcrumbBar` 组件

**Files:**
- Create: `agentGui/Views/Navigation/UnifiedEditorBreadcrumbBar.swift`

### Step 1：编写完整实现

```swift
// agentGui/Views/Navigation/UnifiedEditorBreadcrumbBar.swift
import SwiftUI

/// 统一面包屑栏：文件路径节点 + LSP symbol 路径节点在同一横向滚动行内渲染。
///
/// 布局：[icon?] [file₀ › file₁ › … › fileN] [› sym₀ › sym₁ › …] [TrailingContent]
///
/// - 文件节点：不可点击的当前文件高亮；祖先节点调用 `onSelectFile`。
/// - 符号节点：siblings > 1 时渲染 Menu 下拉；否则渲染 Button 直接导航。
/// - `symbolPath` 为空时不渲染任何符号节点，也不渲染过渡分隔符。
struct UnifiedEditorBreadcrumbBar<TrailingContent: View>: View {
    let iconSystemName: String?
    let fileItems: [BreadcrumbNavigationItem]
    let symbolPath: [CodeEditorSymbolPathNode]
    let onSelectFile: ((BreadcrumbNavigationItem) -> Void)?
    let onNavigateSymbol: ((CodeEditorRevealRequest) -> Void)?
    @ViewBuilder private let trailingContent: TrailingContent

    init(
        iconSystemName: String? = nil,
        fileItems: [BreadcrumbNavigationItem],
        symbolPath: [CodeEditorSymbolPathNode] = [],
        onSelectFile: ((BreadcrumbNavigationItem) -> Void)? = nil,
        onNavigateSymbol: ((CodeEditorRevealRequest) -> Void)? = nil,
        @ViewBuilder trailingContent: () -> TrailingContent = { EmptyView() }
    ) {
        self.iconSystemName = iconSystemName
        self.fileItems = fileItems
        self.symbolPath = symbolPath
        self.onSelectFile = onSelectFile
        self.onNavigateSymbol = onNavigateSymbol
        self.trailingContent = trailingContent()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    // ── 文件路径节点 ──
                    ForEach(Array(fileItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            chevron
                        }
                        fileNodeView(for: item)
                    }

                    // ── 过渡分隔 + 符号节点 ──
                    if !symbolPath.isEmpty {
                        chevron
                        ForEach(Array(symbolPath.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                chevron
                            }
                            symbolNodeView(node)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingContent
        }
    }

    // MARK: - Private

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func fileNodeView(for item: BreadcrumbNavigationItem) -> some View {
        if let onSelectFile, !item.isCurrent {
            Button {
                onSelectFile(item)
            } label: {
                fileLabel(for: item)
            }
            .buttonStyle(.plain)
            .help(item.url?.path ?? item.title)
        } else {
            fileLabel(for: item)
                .help(item.url?.path ?? item.title)
        }
    }

    private func fileLabel(for item: BreadcrumbNavigationItem) -> some View {
        Text(item.title)
            .font(item.isCurrent ? .caption.weight(.medium) : .caption)
            .foregroundStyle(item.isCurrent ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func symbolNodeView(_ node: CodeEditorSymbolPathNode) -> some View {
        if node.siblings.count > 1 {
            Menu {
                ForEach(node.siblings) { sibling in
                    Button {
                        onNavigateSymbol?(sibling.revealRequest)
                    } label: {
                        Label(sibling.name, systemImage: symbolIconName(for: sibling.symbolKind))
                    }
                }
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind)
            }
            .menuStyle(.borderlessButton)
        } else {
            Button {
                onNavigateSymbol?(node.revealRequest)
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind)
            }
            .buttonStyle(.plain)
        }
    }

    private func symbolLabel(name: String, kind: Int) -> some View {
        HStack(spacing: 3) {
            if let icon = CodeEditorViewModel.symbolKindIconName(for: kind) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func symbolIconName(for kind: Int) -> String {
        CodeEditorViewModel.symbolKindIconName(for: kind) ?? "square.dashed"
    }
}
```

### Step 2：确认编译无误（在 Xcode 中 Build 或命令行检查）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`，无 `error:`。

### Step 3：Commit

```bash
git add agentGui/Views/Navigation/UnifiedEditorBreadcrumbBar.swift
git commit -m "feat(F18): add UnifiedEditorBreadcrumbBar component"
```

---

## Task 2：`CodeEditorView` — 上移符号路径回调，移除本地渲染

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`

目标变更：
1. 删除参数 `isSymbolBreadcrumbVisible: Bool`、`onSymbolNavigate`（改由 `FileEditorView` 处理）。
2. 新增参数 `onSymbolPathChange: (([CodeEditorSymbolPathNode]) -> Void)? = nil`。
3. 删除 `body` 中的 `if isSymbolBreadcrumbVisible { CodeEditorSymbolBreadcrumbBar(...) Divider() }` 块。
4. 添加 `.onChange(of: document.selectedRange)` 触发回调（初始化时也触发一次）。

### Step 1：修改参数列表

将：
```swift
var isSymbolBreadcrumbVisible: Bool = false
var onSymbolNavigate: ((CodeEditorRevealRequest) -> Void)? = nil
```

改为：
```swift
var onSymbolPathChange: (([CodeEditorSymbolPathNode]) -> Void)? = nil
```

同时在 `init` 中删除对 `isSymbolBreadcrumbVisible` / `onSymbolNavigate` 的赋值，添加 `onSymbolPathChange` 的赋值：
```swift
self.onSymbolPathChange = onSymbolPathChange
```

### Step 2：删除本地渲染块

从 `body` 中删除以下代码段（约 10 行）：

```swift
if isSymbolBreadcrumbVisible {
    CodeEditorSymbolBreadcrumbBar(
        path: symbolBreadcrumbPath,
        onNavigate: onSymbolNavigate
    )
    .padding(.horizontal, 10)
    .padding(.vertical, 2)
    .background(.bar)

    Divider()
}
```

### Step 3：添加 onChange 回调

在 `body` 的 modifier chain（已有若干 `.onChange(of:)`）中追加：

```swift
.onChange(of: document.selectedRange) { _, _ in
    onSymbolPathChange?(symbolBreadcrumbPath)
}
.onChange(of: documentSymbols) { _, _ in
    onSymbolPathChange?(symbolBreadcrumbPath)
}
.onAppear {
    // 已有 onAppear，在其中追加：
    onSymbolPathChange?(symbolBreadcrumbPath)
}
```

> **注意**：现有 `onAppear` 中已有 `onStatusBarSummaryChange?(statusBarState.summaryText)` 等调用，在同一个 `onAppear` block 内追加 `onSymbolPathChange?(symbolBreadcrumbPath)` 即可。

### Step 4：确认编译无误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`。

### Step 5：Commit

```bash
git add agentGui/Views/CodeEditor/CodeEditorView.swift
git commit -m "refactor(F18): uplift symbol path as callback, remove local CodeEditorSymbolBreadcrumbBar"
```

---

## Task 3：`FileEditorView` — 替换为 `UnifiedEditorBreadcrumbBar`

**Files:**
- Modify: `agentGui/Views/FileEditorView.swift`

目标变更：
1. 新增 `@State private var currentSymbolPath: [CodeEditorSymbolPathNode] = []`。
2. 在 `editorView(for:)` 中，将原来的 `FilePathBreadcrumbBar(...)` 替换为 `UnifiedEditorBreadcrumbBar(...)`，并把 `TrailingContent` 保持原样。
3. 在 `CodeEditorView(...)` 调用处，删除 `isSymbolBreadcrumbVisible:` / `onSymbolNavigate:` 参数，添加 `onSymbolPathChange:` 回调更新 `currentSymbolPath`。
4. **`fileContentView(for:)` 中的 `CodeEditorView` 调用也需同步修改**（删除 `isSymbolBreadcrumbVisible` / `onSymbolNavigate`，增加 `onSymbolPathChange`）。

### Step 1：新增 State

在 `FileEditorView` 的 `// MARK: - State` 区域，已有：
```swift
@State private var rawDocumentSymbols: [LSPDocumentSymbol] = []
```

在其后追加：
```swift
@State private var currentSymbolPath: [CodeEditorSymbolPathNode] = []
```

### Step 2：替换 breadcrumb bar

`editorView(for:)` 中原来的：
```swift
FilePathBreadcrumbBar(
    iconSystemName: fileViewerIconName,
    items: breadcrumbItems(for: url)
) {
    // ... trailing content ...
}
.padding(.horizontal, 10)
.padding(.vertical, 6)
.background(.bar)
```

改为：
```swift
UnifiedEditorBreadcrumbBar(
    iconSystemName: fileViewerIconName,
    fileItems: breadcrumbItems(for: url),
    symbolPath: sessionController.document.viewer == .text ? currentSymbolPath : []
) {
    // ... trailing content 保持完全不变 ...
}
.padding(.horizontal, 10)
.padding(.vertical, 6)
.background(.bar)
```

> **说明**：只有在 `viewer == .text`（代码编辑器模式）时才展示符号路径；PDF 等其他 viewer 不需要符号节点。

### Step 3：更新 `CodeEditorView` 调用

找到 `fileContentView(for:)` 中调用 `CodeEditorView` 的地方，删除：
```swift
isSymbolBreadcrumbVisible: ...,
onSymbolNavigate: { ... },
```

添加：
```swift
onSymbolPathChange: { path in
    currentSymbolPath = path
},
```

同时补充 `onNavigateSymbol` 在 `UnifiedEditorBreadcrumbBar` 中的传递（Step 2 的 label code 里已写 `onNavigateSymbol:`），让它调用 `executeNavigationAction()`：
```swift
UnifiedEditorBreadcrumbBar(
    ...
    onNavigateSymbol: { request in
        executeNavigationAction(
            CodeEditorViewModel.navigationAction(
                currentFileURL: url,
                revealRequest: request
            )
        )
    }
) { ... }
```

### Step 4：处理 `fileURL` 切换时重置符号路径

在已有的 `.onChange(of: fileURL)` block 的重置逻辑末尾：
```swift
currentSymbolPath = []
```

### Step 5：确认编译无误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`。

### Step 6：Commit

```bash
git add agentGui/Views/FileEditorView.swift
git commit -m "feat(F18): replace FilePathBreadcrumbBar with UnifiedEditorBreadcrumbBar in FileEditorView"
```

---

## Task 4：清理废弃组件

**Files:**
- Delete: `agentGui/Views/Navigation/FilePathBreadcrumbBar.swift`（确认无其他引用后）
- Delete: `agentGui/Views/CodeEditor/CodeEditorSymbolBreadcrumbBar.swift`（确认无其他引用后）

### Step 1：确认无其他调用

```bash
grep -rn "FilePathBreadcrumbBar\|CodeEditorSymbolBreadcrumbBar" \
  agentGui/ agentGuiTests/ agentGuiUITests/ \
  --include="*.swift"
```

预期：**零匹配**（计划文档 `docs/` 目录除外）。

若有残余引用，先修复再删除。

### Step 2：从 Xcode 项目中移除文件

在 Xcode 中右键 → "Delete" → "Move to Trash"（或使用 `git rm`）：

```bash
git rm agentGui/Views/Navigation/FilePathBreadcrumbBar.swift
git rm agentGui/Views/CodeEditor/CodeEditorSymbolBreadcrumbBar.swift
```

> ⚠️ 删除后需在 `agentGui.xcodeproj/project.pbxproj` 中确认引用已移除；若用 `git rm` 配合 Xcode 自动清理则无需手动编辑 pbxproj。

### Step 3：确认编译无误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`。

### Step 4：Commit

```bash
git add -A
git commit -m "chore(F18): remove obsolete FilePathBreadcrumbBar and CodeEditorSymbolBreadcrumbBar"
```

---

## Task 5：运行现有测试验证无回归

现有与面包屑/视图相关的测试组：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f18-breadcrumb \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

预期：所有 `CodeEditorViewModelTests` 通过（包括 `symbolBreadcrumbPath*` 系列用例）。

### Step 2：Commit（如有测试修复）

```bash
git commit -m "test(F18): fix any test breakage after breadcrumb bar unification"
```

---

## 边界情况 & 注意事项

| 场景 | 处理方式 |
|------|---------|
| 文件路径节点 + 符号节点均为空 | `UnifiedEditorBreadcrumbBar` 渲染空 HStack，高度由 padding 维持 |
| `viewer != .text`（PDF / 图片等） | `symbolPath: []`，不渲染符号节点，等价原 `FilePathBreadcrumbBar` |
| 切换 `fileURL` | `currentSymbolPath = []` 立即清空，避免残留符号节点跳动 |
| 符号路径有 1 个节点但 siblings 为空 | `symbolNodeView` 走 `else` 分支：单 `Button` 直接跳转 |
| `documentSymbols` 变化（LSP 响应到达）重新计算路径 | `CodeEditorView.onChange(of: documentSymbols)` 触发 `onSymbolPathChange` |
| 横向内容过多时滚动 | 整条 `HStack` 在同一 `ScrollView` 内，文件+符号节点共享滚动区域 |

---

## 不在本期范围内（YAGNI）

- 文件节点弹出文件夹浏览 Picker（VSCode BreadcrumbsFilePicker 等效）
- 符号节点 siblings 超过阈值时改用 Quick Pick（VSCode BreadcrumbsOutlinePicker 等效）
- 面包屑右键菜单 / 复制路径功能（VSCode `CopyBreadcrumbPath` 命令等效）
- 面包屑 focus/keyboard-navigation 快捷键
