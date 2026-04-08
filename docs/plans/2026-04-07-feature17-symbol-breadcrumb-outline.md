# Feature 17: 文档符号面包屑与大纲导航 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `CodeEditorView` 内嵌入符号面包屑导航栏（symbol breadcrumb bar），展示当前光标所在的 symbol 路径（如 `MyClass > init()`），并实现 ⌘⇧O 触发当前文件 symbol 列表快速跳转浮层。

**Architecture:**
- `CodeEditorViewModel` 新增纯函数 `symbolBreadcrumbPath(for:in:)` 和 `symbolKindIconName(for:)` ——不依赖 UI，可单独测试。
- `CodeEditorSymbolBreadcrumbBar` (SwiftUI `View`) 绑定到 `CodeEditorView` 并替代原有设计中"File Path Breadcrumb"之后的符号段；`CodeEditorView` 新增 `documentSymbols` + `currentLine` 参数，自行推导面包屑路径，宿主（`FileEditorView`）只传数据。
- Symbol Outline 复用 `CommandPaletteView` 的搜索+键盘导航模式，在 `FileEditorView` 里托管（sheet 或 popover）。

**Tech Stack:** Swift 6, SwiftUI (macOS), existing LSP models (`LSPDocumentSymbol`), existing `CodeEditorViewModel` static functions pattern, existing `FilePathBreadcrumbBar` for visual reference.

**VSCode 参考要点：**
- `OutlineModel._getItemEnclosingPosition`：递归找包含光标 position 的最深 symbol（使用 `symbol.range` 包含检测，depth-first，优先最深子节点）。
- `BreadcrumbsModel.getElements()`：返回文件路径 + symbol 路径的拼接，symbol 路径来自 `breadcrumbsDataSource.getBreadcrumbElements()`（已按 cursor 位置预先 slice）。
- 每个面包屑节点点击后展示同级 sibling 列表（`BreadcrumbsOutlinePicker`）供选择。

**Zed 参考要点：**
- `crates/editor/src/breadcrumbs.rs`：`breadcrumb_text()` 返回当前 cursor 所处 symbol 名称列表，通过语法树 outline provider 实现；`render_breadcrumbs()` 在 toolbar 渲染以 `>` 分隔的文字节点。
- Zed 对没有 end range 的 symbol（`SymbolInformation` 格式）回退到只有 `line` 的最近匹配（取 `line` 最大且 ≤ cursorLine 的 symbol）。

---

## Task 1：ViewModel 层 — 符号路径推导 & kind 图标映射

**Files:**
- Modify: `agentGui/ViewModels/CodeEditorViewModel.swift`
- Test: `agentGuiTests/CodeEditorViewModelTests.swift`

新增两个 static 方法，放在现有 `CodeEditorViewModel` enum 中。

### Step 1: 写失败测试

在 `agentGuiTests/CodeEditorViewModelTests.swift` 末尾追加：

```swift
// MARK: - Symbol Breadcrumb Path

@Test
func symbolBreadcrumbPathReturnsEmptyWhenNoSymbols() {
    let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 5, in: [])
    #expect(path.isEmpty)
}

@Test
func symbolBreadcrumbPathFindsTopLevelEnclosingSymbol() {
    let symbols = [
        LSPDocumentSymbol(name: "MyClass", detail: nil, kind: 5,
                          line: 1, character: 0, endLine: 20, endCharacter: 1),
        LSPDocumentSymbol(name: "Other", detail: nil, kind: 5,
                          line: 22, character: 0, endLine: 30, endCharacter: 1),
    ]
    let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 10, in: symbols)
    #expect(path.count == 1)
    #expect(path[0].name == "MyClass")
}

@Test
func symbolBreadcrumbPathRecursesIntoBestChild() {
    let methodSymbol = LSPDocumentSymbol(
        name: "doWork()", detail: nil, kind: 12,
        line: 5, character: 4, endLine: 10, endCharacter: 5
    )
    let classSymbol = LSPDocumentSymbol(
        name: "MyClass", detail: nil, kind: 5,
        line: 1, character: 0, endLine: 20, endCharacter: 1,
        children: [methodSymbol]
    )
    let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 7, in: [classSymbol])
    #expect(path.count == 2)
    #expect(path[0].name == "MyClass")
    #expect(path[1].name == "doWork()")
}

@Test
func symbolBreadcrumbPathReturnsEmptyWhenCursorBetweenSymbols() {
    let symbols = [
        LSPDocumentSymbol(name: "A", detail: nil, kind: 12,
                          line: 1, character: 0, endLine: 3, endCharacter: 1),
        LSPDocumentSymbol(name: "B", detail: nil, kind: 12,
                          line: 5, character: 0, endLine: 8, endCharacter: 1),
    ]
    // cursor at line 4 — between A (ends 3) and B (starts 5)
    let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 4, in: symbols)
    #expect(path.isEmpty)
}

@Test
func symbolBreadcrumbPathFallsBackForSymbolsWithoutEndLine() {
    // SymbolInformation format (no end range): pick last symbol whose line ≤ cursorLine
    let symbols = [
        LSPDocumentSymbol(name: "A", detail: nil, kind: 12,
                          line: 1, character: 0, endLine: nil, endCharacter: nil),
        LSPDocumentSymbol(name: "B", detail: nil, kind: 12,
                          line: 5, character: 0, endLine: nil, endCharacter: nil),
        LSPDocumentSymbol(name: "C", detail: nil, kind: 12,
                          line: 10, character: 0, endLine: nil, endCharacter: nil),
    ]
    // cursor at line 7 → B (line 5) is nearest ≤ 7
    let path = CodeEditorViewModel.symbolBreadcrumbPath(for: 7, in: symbols)
    #expect(path.count == 1)
    #expect(path[0].name == "B")
}

// MARK: - Symbol Kind Icon

@Test
func symbolKindIconNameReturnsSFSymbolsForKnownKinds() {
    // LSP SymbolKind: 5 = Class, 12 = Function, 13 = Variable, 9 = Constructor
    #expect(CodeEditorViewModel.symbolKindIconName(for: 5) != nil)   // Class
    #expect(CodeEditorViewModel.symbolKindIconName(for: 12) != nil)  // Function
    #expect(CodeEditorViewModel.symbolKindIconName(for: 13) != nil)  // Variable
    #expect(CodeEditorViewModel.symbolKindIconName(for: 999) == nil) // unknown
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-derived \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：编译错误 "no 'symbolBreadcrumbPath' in scope"。

### Step 3: 实现 `symbolBreadcrumbPath` 和 `symbolKindIconName`

在 `CodeEditorViewModel.swift` 现有最后一个 `private static func` 之前插入：

```swift
// MARK: - Symbol Breadcrumb Path

/// 返回包含 cursorLine 的 symbol 路径（从最外层到最内层）。
/// cursorLine 已是 1-based（与 LSPDocumentSymbol.line + 1 对应）。
///
/// 算法：对每级 symbols 深度优先搜索包含 cursorLine 的 symbol，
/// 递归取最深匹配。对于没有 endLine 的 SymbolInformation 格式，
/// 回退到取 line 最大且 ≤ cursorLine 的 symbol（Zed 启发式）。
static func symbolBreadcrumbPath(
    for cursorLine: Int,
    in symbols: [LSPDocumentSymbol]
) -> [LSPDocumentSymbol] {
    // 先尝试精确 range 包含（DocumentSymbol 格式，有 endLine）
    let symbolsWithRange = symbols.filter { $0.endLine != nil }
    if !symbolsWithRange.isEmpty {
        for symbol in symbolsWithRange {
            guard let endLine = symbol.endLine else { continue }
            // LSPDocumentSymbol.line 是 0-based；cursorLine 是 1-based
            let startLine1 = symbol.line + 1
            let endLine1 = endLine + 1
            guard (startLine1...endLine1).contains(cursorLine) else { continue }
            let childPath = symbolBreadcrumbPath(for: cursorLine, in: symbol.children)
            return [symbol] + childPath
        }
        return []
    }

    // 回退：SymbolInformation 格式（无 endLine），Zed 策略
    // 取 line 最大且 ≤ cursorLine - 1（因为 LSP line 是 0-based）的 symbol
    let fallback = symbols
        .filter { $0.line + 1 <= cursorLine }
        .max(by: { $0.line < $1.line })
    return fallback.map { [$0] } ?? []
}

/// LSP SymbolKind 整数 → SF Symbols 名称（用于面包屑图标）。
/// 返回 nil 表示未识别的 kind，调用方可用通用图标替代。
/// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
static func symbolKindIconName(for kind: Int) -> String? {
    switch kind {
    case 1:  return "doc.text"            // File
    case 2:  return "square.stack"        // Module
    case 3:  return "square.stack"        // Namespace
    case 4:  return "shippingbox"         // Package
    case 5:  return "c.square"            // Class
    case 6:  return "m.square"            // Method
    case 7:  return "p.square"            // Property
    case 8:  return "f.square"            // Field
    case 9:  return "c.square.fill"       // Constructor
    case 10: return "e.square"            // Enum
    case 11: return "i.square"            // Interface
    case 12: return "f.square.fill"       // Function
    case 13: return "v.square"            // Variable
    case 14: return "number.square"       // Constant
    case 15: return "s.square"            // String
    case 16: return "n.square"            // Number
    case 17: return "b.square"            // Boolean
    case 18: return "a.square"            // Array
    case 19: return "o.square"            // Object
    case 20: return "k.square"            // Key
    case 21: return "x.square"            // Null
    case 22: return "e.square.fill"       // EnumMember
    case 23: return "s.square.fill"       // Struct
    case 24: return "event"               // Event
    case 25: return "o.square.fill"       // Operator
    case 26: return "t.square"            // TypeParameter
    default: return nil
    }
}
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-derived \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

预期：所有 `CodeEditorViewModelTests` PASS。

### Step 5: Commit

```
git add agentGui/ViewModels/CodeEditorViewModel.swift \
        agentGuiTests/CodeEditorViewModelTests.swift
git commit -m "feat(F17): add symbolBreadcrumbPath and symbolKindIconName to CodeEditorViewModel"
```

---

## Task 2：数据模型 — `CodeEditorSymbolPathNode`

**Files:**
- Modify: `agentGui/Models/CodeEditorSemanticModels.swift`
- Test: `agentGuiTests/CodeEditorViewModelTests.swift`（Task 1 测试已覆盖；本 Task 仅做模型验证）

### Step 1: 在 `CodeEditorSemanticModels.swift` 追加数据模型

在文件末尾追加（不修改现有 struct）：

```swift
/// 面包屑路径中的单个 symbol 节点，携带同级 sibling 列表用于 Menu 下拉。
struct CodeEditorSymbolPathNode: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let detail: String?
    let symbolKind: Int         // LSP SymbolKind integer
    let line: Int               // 1-based
    let revealRequest: CodeEditorRevealRequest
    /// 当前 symbol 在其父节点中的所有同级 symbol（含自身），供面包屑下拉菜单使用。
    let siblings: [CodeEditorSymbolSiblingItem]

    init(
        id: UUID = UUID(),
        name: String,
        detail: String?,
        symbolKind: Int,
        line: Int,
        revealRequest: CodeEditorRevealRequest,
        siblings: [CodeEditorSymbolSiblingItem]
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbolKind = symbolKind
        self.line = line
        self.revealRequest = revealRequest
        self.siblings = siblings
    }
}

/// 面包屑下拉菜单中一个同级 symbol 的极简表示。
struct CodeEditorSymbolSiblingItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let symbolKind: Int
    let revealRequest: CodeEditorRevealRequest

    init(
        id: UUID = UUID(),
        name: String,
        symbolKind: Int,
        revealRequest: CodeEditorRevealRequest
    ) {
        self.id = id
        self.name = name
        self.symbolKind = symbolKind
        self.revealRequest = revealRequest
    }
}
```

### Step 2: 在 `CodeEditorViewModel` 补充 `symbolBreadcrumbNodes` 方法

此方法把 `symbolBreadcrumbPath` 的输出包装为 `[CodeEditorSymbolPathNode]`，同时计算 siblings。

在 `CodeEditorViewModel.swift` 的 MARK: Symbol Breadcrumb Path 区域补充：

```swift
/// 将 symbolBreadcrumbPath 的原始 LSP 结果包装为带 siblings 的 PathNode 数组。
/// - Parameters:
///   - cursorLine: 1-based 行号
///   - symbols: 当前文件的 documentSymbols
///   - fileURL: 用于构造 revealRequest
static func symbolBreadcrumbNodes(
    for cursorLine: Int,
    in symbols: [LSPDocumentSymbol],
    fileURL: URL
) -> [CodeEditorSymbolPathNode] {
    buildNodes(cursorLine: cursorLine, symbols: symbols, fileURL: fileURL)
}

private static func buildNodes(
    cursorLine: Int,
    symbols: [LSPDocumentSymbol],
    fileURL: URL
) -> [CodeEditorSymbolPathNode] {
    // 计算同级 siblings
    let siblings = symbols.map { sym in
        CodeEditorSymbolSiblingItem(
            name: sym.name,
            symbolKind: sym.kind,
            revealRequest: CodeEditorRevealRequest(
                fileURL: fileURL,
                line: sym.line + 1,
                column: sym.character + 1,
                reason: .documentSymbol
            )
        )
    }

    // 找到包含 cursorLine 的那一个（精确 range）
    let symbolsWithRange = symbols.filter { $0.endLine != nil }
    if !symbolsWithRange.isEmpty {
        for sym in symbolsWithRange {
            guard let endLine = sym.endLine else { continue }
            let s1 = sym.line + 1
            let e1 = endLine + 1
            guard (s1...e1).contains(cursorLine) else { continue }
            let node = CodeEditorSymbolPathNode(
                name: sym.name,
                detail: sym.detail,
                symbolKind: sym.kind,
                line: sym.line + 1,
                revealRequest: CodeEditorRevealRequest(
                    fileURL: fileURL,
                    line: sym.line + 1,
                    column: sym.character + 1,
                    reason: .documentSymbol
                ),
                siblings: siblings
            )
            let childNodes = buildNodes(cursorLine: cursorLine, symbols: sym.children, fileURL: fileURL)
            return [node] + childNodes
        }
        return []
    }

    // 回退：无 endLine
    guard let best = symbols.filter({ $0.line + 1 <= cursorLine }).max(by: { $0.line < $1.line }) else {
        return []
    }
    let node = CodeEditorSymbolPathNode(
        name: best.name,
        detail: best.detail,
        symbolKind: best.kind,
        line: best.line + 1,
        revealRequest: CodeEditorRevealRequest(
            fileURL: fileURL,
            line: best.line + 1,
            column: best.character + 1,
            reason: .documentSymbol
        ),
        siblings: siblings
    )
    return [node]
}
```

### Step 3: 写 `symbolBreadcrumbNodes` 快速单元测试（补充到 `CodeEditorViewModelTests.swift`）

```swift
@Test
func symbolBreadcrumbNodesIncludeSiblingsForEachLevel() {
    let method1 = LSPDocumentSymbol(name: "alpha()", detail: nil, kind: 12,
                                    line: 2, character: 4, endLine: 4, endCharacter: 5)
    let method2 = LSPDocumentSymbol(name: "beta()", detail: nil, kind: 12,
                                    line: 6, character: 4, endLine: 8, endCharacter: 5)
    let classSymbol = LSPDocumentSymbol(
        name: "MyClass", detail: nil, kind: 5,
        line: 0, character: 0, endLine: 10, endCharacter: 1,
        children: [method1, method2]
    )
    let url = URL(fileURLWithPath: "/tmp/Foo.swift")
    let nodes = CodeEditorViewModel.symbolBreadcrumbNodes(for: 3, in: [classSymbol], fileURL: url)

    // path depth: MyClass > alpha()
    #expect(nodes.count == 2)
    #expect(nodes[0].name == "MyClass")
    #expect(nodes[1].name == "alpha()")

    // top-level siblings list contains only MyClass
    #expect(nodes[0].siblings.count == 1)

    // method-level siblings: alpha() + beta()
    #expect(nodes[1].siblings.count == 2)
    #expect(nodes[1].siblings.map(\.name).sorted() == ["alpha()", "beta()"])
}
```

### Step 4: 运行测试确认通过，Commit

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-derived \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:"
```

```
git add agentGui/Models/CodeEditorSemanticModels.swift \
        agentGui/ViewModels/CodeEditorViewModel.swift \
        agentGuiTests/CodeEditorViewModelTests.swift
git commit -m "feat(F17): add CodeEditorSymbolPathNode model and symbolBreadcrumbNodes builder"
```

---

## Task 3：`CodeEditorSymbolBreadcrumbBar` SwiftUI 视图

**Files:**
- Create: `agentGui/Views/CodeEditor/CodeEditorSymbolBreadcrumbBar.swift`

### Step 1: 创建新文件

```swift
import SwiftUI

/// 符号路径面包屑栏，展示当前光标所在的 LSP symbol 层级。
/// 每个节点可点击弹出同级 sibling 下拉菜单（SwiftUI Menu），选中后通过
/// onNavigate 回调发出 CodeEditorRevealRequest。
///
/// 当 path 为空时，视图高度保持不变但展示占位文字「(符号)」。
struct CodeEditorSymbolBreadcrumbBar: View {
    let path: [CodeEditorSymbolPathNode]
    var onNavigate: ((CodeEditorRevealRequest) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                if path.isEmpty {
                    Text("(符号)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        symbolNodeView(node)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func symbolNodeView(_ node: CodeEditorSymbolPathNode) -> some View {
        if node.siblings.count > 1 {
            // 有同级 sibling → 用 Menu 展示下拉
            Menu {
                ForEach(node.siblings) { sibling in
                    Button {
                        onNavigate?(sibling.revealRequest)
                    } label: {
                        Label(sibling.name, systemImage: iconName(for: sibling.symbolKind))
                    }
                }
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind, isCurrent: true)
            }
            .menuStyle(.borderlessButton)
        } else {
            // 唯一节点（顶层孤立 symbol）直接可点击
            Button {
                onNavigate?(node.revealRequest)
            } label: {
                symbolLabel(name: node.name, kind: node.symbolKind, isCurrent: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func symbolLabel(name: String, kind: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 3) {
            if let icon = CodeEditorViewModel.symbolKindIconName(for: kind) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(isCurrent ? .caption.weight(.medium) : .caption)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 3)
    }

    private func iconName(for kind: Int) -> String {
        CodeEditorViewModel.symbolKindIconName(for: kind) ?? "square.dashed"
    }
}
```

**注意事项（SwiftUI 最佳实践）：**
- 不使用 `@StateObject` / `@ObservedObject`；所有数据是值类型，通过父视图 `let` 传入。
- `Menu` 在 macOS 上会以 native popup 样式渲染，无需自定义。
- `.menuStyle(.borderlessButton)` 去掉 menu 的边框，视觉与面包屑其他节点一致。

### Step 2: Commit（仅新文件，无测试，下一 Task 在集成中验证）

```
git add agentGui/Views/CodeEditor/CodeEditorSymbolBreadcrumbBar.swift
git commit -m "feat(F17): add CodeEditorSymbolBreadcrumbBar SwiftUI view"
```

---

## Task 4：集成到 `CodeEditorView`

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`

### Step 1: 在 `CodeEditorView` 上增加新参数

在 `struct CodeEditorView: View` 的 stored properties 区域（`var highlighter:` 下方），追加：

```swift
var documentSymbols: [LSPDocumentSymbol] = []
var isSymbolBreadcrumbVisible: Bool = false
var onSymbolNavigate: ((CodeEditorRevealRequest) -> Void)? = nil
```

同理，在 `init(...)` 的参数列表末尾追加：

```swift
documentSymbols: [LSPDocumentSymbol] = [],
isSymbolBreadcrumbVisible: Bool = false,
onSymbolNavigate: ((CodeEditorRevealRequest) -> Void)? = nil,
```

并在 `init` 体内赋值：

```swift
self.documentSymbols = documentSymbols
self.isSymbolBreadcrumbVisible = isSymbolBreadcrumbVisible
self.onSymbolNavigate = onSymbolNavigate
```

### Step 2: 在 `body` 的 `VStack` 中插入符号面包屑

在现有 `VStack(spacing: 0)` 中，`CodeEditorFindBar` 条件块之后、`CodeEditorTextView` 之前，插入：

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

### Step 3: 添加 computed property `symbolBreadcrumbPath`

在 `private var statusBarState:` 后面追加：

```swift
private var symbolBreadcrumbPath: [CodeEditorSymbolPathNode] {
    // document.selectedRange 的位置转为 1-based 行号
    let line = document.location(ofUTF16Offset: document.selectedRange.location).line
    return CodeEditorViewModel.symbolBreadcrumbNodes(
        for: line,
        in: documentSymbols,
        fileURL: fileURL
    )
}
```

> `CodeEditorDocument.location(ofUTF16Offset:)` 已返回 1-based line（见 F2 实现）。

### Step 4: 确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-f17-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```

预期：`BUILD SUCCEEDED`。

### Step 5: Commit

```
git add agentGui/Views/CodeEditor/CodeEditorView.swift
git commit -m "feat(F17): integrate CodeEditorSymbolBreadcrumbBar into CodeEditorView"
```

---

## Task 5：FileEditorView 集成 — 传递 symbols + 开启面包屑

**Files:**
- Modify: `agentGui/Views/FileEditorView.swift`

`FileEditorView` 已在 `@State private var documentSymbolItems` 中缓存了 symbols，但类型是 `[CodeEditorDocumentSymbolItem]`（已扁平化）。F17 需要**原始树结构**的 `[LSPDocumentSymbol]`，以便面包屑路径算法递归。

### Step 1: 在 `FileEditorView` 增加原始 symbols state

在现有 `@State private var documentSymbolItems: [CodeEditorDocumentSymbolItem] = []` **后面**追加：

```swift
@State private var rawDocumentSymbols: [LSPDocumentSymbol] = []
```

### Step 2: 修改 `refreshDocumentSymbols` 同时更新原始 symbols

找到现有的 `private func refreshDocumentSymbols(for url: URL)` 函数，在 `documentSymbolItems = items` 后追加：

```swift
rawDocumentSymbols = symbols
```

（完整上下文：`let items = CodeEditorViewModel.flattenedDocumentSymbols(symbols, fileURL: url)` 之后）

也在 `onChange(of: fileURL)` 清零的地方同步清零：

```swift
rawDocumentSymbols = []
```

### Step 3: 向 `CodeEditorView` 传递 symbols + 开启面包屑

在 `FileEditorView` 内部组装 `CodeEditorView` 的地方（`fileContentView` 或 `editorContentView`），找到 `CodeEditorView(...)` 调用，追加参数：

```swift
documentSymbols: rawDocumentSymbols,
isSymbolBreadcrumbVisible: !rawDocumentSymbols.isEmpty,
onSymbolNavigate: { request in
    executeNavigationAction(
        CodeEditorViewModel.navigationAction(
            currentFileURL: url,
            revealRequest: request
        )
    )
},
```

### Step 4: 编译 + 手工冒烟

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-f17-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```

打开应用，在代码编辑器中移动光标到一个函数内（LSP 激活状态下），等待 symbols 加载后，面包屑栏应显示类名 > 方法名。

### Step 5: Commit

```
git add agentGui/Views/FileEditorView.swift
git commit -m "feat(F17): pass rawDocumentSymbols to CodeEditorView for symbol breadcrumb"
```

---

## Task 6：Symbol Outline 快速跳转面板（⌘⇧O）

**Files:**
- Create: `agentGui/Views/CodeEditor/CodeEditorSymbolOutlineView.swift`
- Modify: `agentGui/Views/FileEditorView.swift`

### Step 1: 创建 `CodeEditorSymbolOutlineView`

此视图复用 `CommandPaletteView` 的「搜索框 + 列表 + 键盘导航」模式，但不依赖其实现。

```swift
import SwiftUI

/// ⌘⇧O 触发的「转到符号」快速跳转面板。
/// 展示当前文件所有扁平化 symbols，支持模糊过滤，Enter 跳转，Esc 关闭。
struct CodeEditorSymbolOutlineView: View {
    let symbols: [CodeEditorDocumentSymbolItem]
    var onNavigate: ((CodeEditorRevealRequest) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 搜索输入框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.body)
                TextField("转到符号...", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onKeyPress(.escape) {
                        onDismiss?()
                        return .handled
                    }
                    .onKeyPress(.return) {
                        commitSelection()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // 符号列表
            if filteredSymbols.isEmpty {
                Text("无匹配符号")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredSymbols.enumerated()), id: \.element.id) { index, item in
                                symbolRow(item, index: index)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 420)
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 10))
        .shadow(radius: 12)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private var filteredSymbols: [CodeEditorDocumentSymbolItem] {
        guard !query.isEmpty else { return symbols }
        return symbols.filter {
            $0.title.localizedStandardContains(query)
        }
    }

    private func symbolRow(_ item: CodeEditorDocumentSymbolItem, index: Int) -> some View {
        Button {
            selectedIndex = index
            commitSelection()
        } label: {
            HStack(spacing: 8) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func commitSelection() {
        guard !filteredSymbols.isEmpty, filteredSymbols.indices.contains(selectedIndex) else { return }
        onNavigate?(filteredSymbols[selectedIndex].revealRequest)
        onDismiss?()
    }

    private func moveSelection(by delta: Int) {
        let count = filteredSymbols.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }
}
```

### Step 2: 在 `FileEditorView` 增加 ⌘⇧O 触发与 overlay 展示

在 `FileEditorView` 的 state 区域追加：

```swift
@State private var isSymbolOutlinePresented: Bool = false
```

在 `body` 视图的最外层（`editorView(for: fileURL)` 的 `.onAppear` 等修饰符同层），追加：

```swift
.overlay(alignment: .top) {
    if isSymbolOutlinePresented {
        CodeEditorSymbolOutlineView(
            symbols: documentSymbolItems,
            onNavigate: { request in
                isSymbolOutlinePresented = false
                executeNavigationAction(
                    CodeEditorViewModel.navigationAction(
                        currentFileURL: fileURL,
                        revealRequest: request
                    )
                )
            },
            onDismiss: {
                isSymbolOutlinePresented = false
            }
        )
        .padding(.top, 40)
    }
}
.keyboardShortcut("o", modifiers: [.command, .shift])  // ⌘⇧O
```

**注意：** `.keyboardShortcut` 触发一个 `Button` 切换 `isSymbolOutlinePresented`。  
由于 SwiftUI 的 `.keyboardShortcut` 要求附着在 Button 上，实际实现方式改为：

在 `body` 的末尾追加一个**零尺寸隐藏 Button**：

```swift
.background {
    Button("") {
        if sessionController.document.viewer == .text {
            isSymbolOutlinePresented.toggle()
            if isSymbolOutlinePresented && documentSymbolItems.isEmpty {
                refreshDocumentSymbols(for: fileURL)
            }
        }
    }
    .keyboardShortcut("o", modifiers: [.command, .shift])
    .hidden()
    .accessibilityHidden(true)
}
```

### Step 3: Esc 键关闭（已在 `CodeEditorSymbolOutlineView` 内处理）

`CodeEditorSymbolOutlineView` 的 `onKeyPress(.escape)` 调用 `onDismiss`，已覆盖。

### Step 4: 编译确认

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-f17-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED"
```

### Step 5: Commit

```
git add agentGui/Views/CodeEditor/CodeEditorSymbolOutlineView.swift \
        agentGui/Views/FileEditorView.swift
git commit -m "feat(F17): add CodeEditorSymbolOutlineView and cmd+shift+O shortcut"
```

---

## Task 7：集成测试（符号面包屑路径算法回归 + Xcode Scheme 验证）

**Files:**
- Test: `agentGuiTests/CodeEditorViewModelTests.swift`（追加）

用专门的 F17 集成测试作为回归保护。

### Step 1: 在 `CodeEditorViewModelTests.swift` 追加集成场景测试

```swift
// MARK: - F17 Symbol Breadcrumb Integration

@Test
func symbolBreadcrumbNodesHandlesNestedEnumCasesCorrectly() {
    // 模拟 Swift 枚举 + case 的 LSP 输出
    let caseA = LSPDocumentSymbol(name: "caseA", detail: nil, kind: 22,
                                  line: 3, character: 4, endLine: 3, endCharacter: 10)
    let caseB = LSPDocumentSymbol(name: "caseB", detail: nil, kind: 22,
                                  line: 4, character: 4, endLine: 4, endCharacter: 10)
    let enumSym = LSPDocumentSymbol(
        name: "MyError", detail: nil, kind: 10,
        line: 2, character: 0, endLine: 5, endCharacter: 1,
        children: [caseA, caseB]
    )
    let url = URL(fileURLWithPath: "/tmp/MyError.swift")

    // cursor on caseB (line 5 = endLine of caseB → 1-based 5)
    // LSP line 4 → 1-based 5
    let nodes = CodeEditorViewModel.symbolBreadcrumbNodes(for: 5, in: [enumSym], fileURL: url)
    #expect(nodes.count == 2)
    #expect(nodes[0].name == "MyError")
    #expect(nodes[1].name == "caseB")
    #expect(nodes[1].siblings.count == 2)
}

@Test
func symbolBreadcrumbNodesReturnsEmptyForCursorAfterLastSymbol() {
    let sym = LSPDocumentSymbol(name: "Foo", detail: nil, kind: 5,
                                line: 0, character: 0, endLine: 10, endCharacter: 1)
    let url = URL(fileURLWithPath: "/tmp/Foo.swift")
    let after = CodeEditorViewModel.symbolBreadcrumbNodes(for: 20, in: [sym], fileURL: url)
    #expect(after.isEmpty)
}

@Test
func symbolKindIconNameCoversAllLSPKinds() {
    // LSP SymbolKind 1–26 should all return non-nil
    for kind in 1...26 {
        #expect(CodeEditorViewModel.symbolKindIconName(for: kind) != nil,
                "Missing icon for kind \(kind)")
    }
}
```

### Step 2: 运行全量 ViewModel Tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-derived \
  -only-testing:agentGuiTests/CodeEditorViewModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|passed|failed|error:"
```

预期：所有测试 PASS，无 failure。

### Step 3: 运行既有 smoke 测试，确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f17-derived \
  -only-testing:agentGuiTests/CodeEditorViewIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed|passed|failed|error:"
```

### Step 4: Final Commit

```
git add agentGuiTests/CodeEditorViewModelTests.swift
git commit -m "test(F17): add symbol breadcrumb path integration tests"
```

---

## Task 8：Xcode Scheme 新增 F17 专项测试任务（tasks.json）

**Files:**
- Modify: `.vscode/tasks.json`

在现有任务列表中追加：

```json
{
    "label": "F17 Symbol Breadcrumb Tests",
    "type": "shell",
    "command": "xcodebuild",
    "args": [
        "test",
        "-project", "agentGui.xcodeproj",
        "-scheme", "agentGui",
        "-destination", "platform=macOS",
        "-parallel-testing-enabled", "NO",
        "-derivedDataPath", "/tmp/agentGui-f17-symbols-derived",
        "-only-testing:agentGuiTests/CodeEditorViewModelTests",
        "CODE_SIGNING_ALLOWED=NO"
    ],
    "isBackground": false,
    "group": "test"
}
```

```
git add .vscode/tasks.json
git commit -m "chore(F17): add F17 Symbol Breadcrumb Tests task to tasks.json"
```

---

## 实现完成验收标准

1. **单元测试全绿：** `CodeEditorViewModelTests` 所有测试 PASS（含 F17 新增的 7 个用例）。
2. **面包屑路径准确：** 在 Swift/Python 文件中将光标移至函数体内，面包屑栏展示正确的 `类名 > 方法名` 路径；光标在顶层（不在任何符号内）时面包屑栏展示占位文字「(符号)」。
3. **节点点击下拉：** 点击面包屑中的类名节点，弹出同文件同级类的下拉列表；选中后光标跳转到对应行。
4. **⌘⇧O 快速符号跳转：** 按 ⌘⇧O 출현 outline 浮层；搜索框支持模糊过滤；⬆⬇ 键选择；Enter 跳转；Esc 关闭。
5. **LSP 未就绪时静默：** 无 LSP symbols 时面包屑栏不显示（`isSymbolBreadcrumbVisible = false`），不报错。
6. **无回归：** `CodeEditorViewIntegrationTests` 和 `CodeEditorTextViewIntegrationTests` 全部通过。

---

## 关键设计限制与已知问题

| 限制 | 说明 |
|------|------|
| `endLine` 缺失 | `SymbolInformation` 格式（旧 LSP 服务）不含 end range，用"最近 line ≤ cursor"回退策略，可能不准确（与 Zed 一致） |
| 光标实时性 | `symbolBreadcrumbPath` 是纯 computed property，依赖 `document.selectedRange` 变化触发 SwiftUI 重绘；对每次光标移动都重新计算，当 symbols 数量 > 500 时可能有微小开销，首轮不优化 |
| Menu 性能 | siblings 列表超过 50 项时 `Menu` 的原生渲染可能变慢，首轮不加虚拟化（符号数通常 < 30 同级） |
| Xcode scheme 注册 | 新创建的 `CodeEditorSymbolBreadcrumbBar.swift` 和 `CodeEditorSymbolOutlineView.swift` 需要手动添加到 Xcode 项目的 target membership（或使用 `agentGui.xcodeproj` 的 folder reference 模式自动引入） |

---

## 外部参考

| 参考 | 关联 Task | 要点 |
|------|-----------|------|
| [VSCode breadcrumbsModel.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/breadcrumbsModel.ts) | Task 1-2 | `getBreadcrumbElements()` 按 outline provider 的 cursor position 切片 |
| [VSCode outlineModel.ts `_getItemEnclosingPosition`](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/documentSymbols/browser/outlineModel.ts) | Task 1 | depth-first 递归 range containment；优先最深 child |
| [VSCode breadcrumbsControl.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/breadcrumbsControl.ts) | Task 3-5 | 点击 OutlineItem → `BreadcrumbsOutlinePicker` 展示同级 sibling |
| Zed `breadcrumbs.rs` | Task 1 | 对无 end range symbols 的 fallback 策略（最近 startLine ≤ cursor） |
| [Apple NSMenuDelegate 文档](https://developer.apple.com/documentation/appkit/nsmenudelegate) | Task 3 | SwiftUI Menu 在 macOS 上使用 NSMenu 渲染，性能有原生保证 |
