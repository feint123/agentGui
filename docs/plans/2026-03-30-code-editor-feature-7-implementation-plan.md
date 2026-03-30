# Code Editor Feature 7 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为现有 CodeEditor 主路径补上当前文档查找高亮、当前选区匹配高亮与 diagnostics underline，并把装饰更新收敛到 line-scoped invalidation 和局部属性回写，避免装饰层变化时回退到整段 attributed text 覆盖。

**Architecture:** 这一轮不重写 Highlightr 管线，也不把装饰逻辑塞成第二套文本系统。继续以 `CodeEditorHighlightPipeline` 产出的语法高亮作为基础层，在 `CodeEditorViewModel` 和一个轻量装饰模型里投影 find matches、selection matches 和 diagnostics ranges；`CodeEditorTextView` 只在可见区与脏行范围内合并这些装饰，并通过逐行 fragment 应用与指纹比较做到最小失效。当前仓库没有可复用的“当前文档查找状态”实现，因此本 Feature 需要顺带补一个 editor-local find bar，而不是依赖 AppKit 默认查找高亮黑盒。

**Tech Stack:** Swift 6、SwiftUI、AppKit、TextKit、Foundation、现有 `CodeEditorView` / `CodeEditorTextView` / `CodeEditorHighlightPipeline` / `CodeEditorViewModel` / `LSPClient` / `LSPDiagnosticsStore`、Swift Testing

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 当前执行状态（2026-03-30）

- Feature 1-6 的主骨架已经在仓库中：`CodeEditorView`、`CodeEditorTextView`、`CodeEditorDocument`、`CodeEditorLineIndex`、viewport-only 高亮、gutter、`CodeEditorLSPCoordinator` 与 hover / definition / references 都已落地。
- 当前 `CodeEditorHighlightApplicator` 已经不是“整份文档回写”，但它仍以 `replacementRange` 为单位先 `setAttributes(baseAttributes, range:)`，再重放 Highlightr 结果；这意味着只要装饰层变化，就很容易把整个 retained window 重新洗一遍，而不是只动受影响的行。
- 当前编辑器没有当前文档查找状态，也没有 selection matches 或 diagnostics underline。仓库里唯一与查找相关的现成能力是 `CodeEditorPlatformTextView.usesFindPanel = true`，但没有任何可供测试和最小失效渲染复用的 query / matches / decoration state。
- `CodeEditorTextView` 已经具备这轮最需要的基础事件：选区变化、可见区变化、程序性 reveal、hover 取消、输入法组合态保护，以及 `onVisibleLineRangeChange` 回调；Feature 7 应该复用这些已存在的事件流，而不是再造一套通知。
- 当前 `LSPDiagnostic` 只有 `line` 与 `character` 起点，没有结束位置；如果要真正做 diagnostics underline，而不是整行洗色，必须先把诊断范围扩成可选的 `endLine/endCharacter`。
- `CodeEditorView` 当前还没有消费 `onVisibleLineRangeChange`，`CodeEditorViewModel` 也只做状态栏和按行 diagnostics summary；Feature 7 的装饰投影应优先放在这些既有纯值层上，而不是让 `CodeEditorPlatformTextView` 自己扫描全文字符串。

## 0. 范围约束

- Feature 7 只做“当前文档”范围内的查找与装饰，不实现跨文件搜索、替换、replace all、workspace grep 或 symbol search。
- Feature 7 不新增 minimap、folding、inline diff、多光标或 code action UI；这些都与本轮的最小失效验证无关。
- Feature 7 不允许在 query 变化、选区变化或 diagnostics 刷新时对整个可见窗口以外的文本做整段属性重写；装饰层更新必须以行或更小范围作为最小应用单位。
- Feature 7 不把 diagnostics underline 退化成整行背景染色。当前行洗色已经由 Feature 4 提供；本轮要新增的是范围级 underline，并且它必须能局部更新。
- Feature 7 可以新增一个最小 find bar，因为仓库中没有现成的当前文档搜索状态，但不需要在这一轮做完整 IDE 级查找体验；首轮只要做到 query、match count、关闭和基础导航即可。
- Feature 7 继续遵守“输入主路径优先”的原则：键入文本、修改选区、组合输入时不能等待查找投影、diagnostics merge 或装饰回写完成。
- 这个 Xcode 工程使用 `PBXFileSystemSynchronizedRootGroup`；在 `agentGui` 和 `agentGuiTests` 下新增 Swift 文件通常不需要手动修改工程文件。

## 1. 代码锚点

当前与 Feature 7 直接相关的真实落点如下：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
  这里已经掌握 `NSTextView`、当前选区、可见区、程序性 reveal、hover 取消和高亮调度，是“查找 query 改变后只重刷受影响行”和“选区匹配高亮跟随 selection 变化”的主入口。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
  这是当前 SwiftUI 宿主壳层，已经持有 `CodeEditorDocument` 状态，但还没有 find bar、可见区状态和装饰投影入口。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
  当前只负责状态栏和按行 diagnostics 聚合，正适合继续承接“find matches / selection matches / diagnostics underline spans”的纯值投影逻辑。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
  当前仍输出单个 `replacementRange + attributedString`，是本轮把结果改成 line fragments 或可局部对比结果的关键落点。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
  当前 `LSPDiagnostic` 只有起始位置，无法精确表达 underline 终点。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
  这里负责从 publishDiagnostics 解析协议 payload；如果要补 `endLine/endCharacter`，这里必须跟着扩展。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`
  这里适合锁定纯值投影：query -> matches、selection -> selection matches、diagnostics -> underline spans。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorHighlightPipelineTests.swift`
  这里适合锁定 retained window 下的 fragment 拆分、指纹稳定性和“只发布受影响行”的契约。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
  这里已经有现成 AppKit harness，适合验证 find bar / selection match / diagnostics underline 对 text storage 的局部写回不会破坏选区、typing attributes 或 IME。
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
  这里适合验证 `CodeEditorView` 的 find state、visible line range 桥接和 query 改变时的宿主行为。

## 2. 方案结论

本 Feature 建议按下面这条路线落地：

1. 先把装饰层抽成显式模型，而不是让 `CodeEditorPlatformTextView` 每次自己临时扫描文本并直接写属性。具体说，就是新增 `CodeEditorFindState`、`CodeEditorDecorationSpan` 和 `CodeEditorDecorationSnapshot` 这样的纯值类型。
2. `CodeEditorView` 负责持有 editor-local find state 和 visible line range；`CodeEditorViewModel` 负责把 `document + selectedRange + visibleLineRange + diagnostics + findState` 投影成“当前需要画的 decoration spans”。
3. `CodeEditorHighlightPipeline` 不再只产出一个整块 `NSAttributedString`，而是产出 line-scoped fragments 或至少带有每行 fingerprint 的结果，这样装饰层变化时可以只更新受影响行。
4. `CodeEditorTextView` 继续作为唯一 AppKit 输入与属性回写入口：它拿到语法高亮 fragments 和装饰 snapshot 后，把二者合并成局部属性更新，保证 old/new changed lines 才会被应用。
5. diagnostics underline 必须建立在明确范围之上，因此要先把 `LSPDiagnostic` 扩成带可选结束位置的模型；如果语言服务器没给 end range，则保守降级成单字符 underline，而不是整行涂抹。

不建议采用的路线：

- 不要依赖 AppKit 默认 find panel 的内建高亮来“顺便完成 Feature 7”。那条路径拿不到稳定 query state，也无法验证 minimal invalidation，更没法和 diagnostics underline 做统一装饰合并。
- 不要把 diagnostics underline 做成第二层整行 background wash。Feature 4 已经有当前行与 gutter 层了；继续走整行染色只会绕开这轮真正要验证的范围级局部回写。
- 不要在 `CodeEditorPlatformTextView` 里直接维护一堆 ad-hoc 的 `NSRange` 和 `setTemporaryAttributes` 分支逻辑。那样很快会把 syntax / find / selection / diagnostics 的优先级关系写散，后续也很难测。

## 3. 设计细节

### 3.1 装饰模型

建议新增一个轻量模型文件，例如 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDecorationModels.swift`，集中定义本 Feature 需要的纯值类型：

```swift
import Foundation

struct CodeEditorFindState: Equatable, Sendable {
    var isPresented: Bool
    var query: String
    var caseSensitive: Bool
    var selectedMatchIndex: Int?

    static let inactive = CodeEditorFindState(
        isPresented: false,
        query: "",
        caseSensitive: false,
        selectedMatchIndex: nil
    )
}

enum CodeEditorDecorationKind: Equatable, Sendable {
    case findMatch
    case activeFindMatch
    case selectionMatch
    case diagnosticUnderline(LSPDiagnosticSeverity)
}

struct CodeEditorDecorationSpan: Equatable, Sendable, Identifiable {
    let id: UUID
    let utf16Range: NSRange
    let line: Int
    let kind: CodeEditorDecorationKind
}

struct CodeEditorDecorationSnapshot: Equatable, Sendable {
    let version: Int
    let lineRange: ClosedRange<Int>
    let spansByLine: [Int: [CodeEditorDecorationSpan]]
}
```

这里不要把 `NSColor`、`NSUnderlineStyle` 或 `NSTextView` 相关状态放进模型层。模型只负责表达“哪一段文本需要什么语义装饰”；具体颜色、underline style 和优先级合并规则留给应用层。这样测试可以直接对 span 结果做断言，而不用在纯逻辑测试里碰 AppKit。

### 3.2 当前文档查找与选区匹配投影

当前仓库没有 editor-local find state，因此 Feature 7 需要一套最小可用的查找 UI 和状态机。建议如下：

- `CodeEditorView` 新增 `@State private var findState = CodeEditorFindState.inactive`
- `CodeEditorView` 同时开始消费 `onVisibleLineRangeChange`，把可见区缓存成本地 state
- 新增 `CodeEditorFindBar`，显示 query、match count、上一处 / 下一处和关闭按钮
- `CodeEditorPlatformTextView` 通过一个轻量回调把 `Cmd-F`、`Enter`、`Shift-Enter` 和 `Escape` 翻译成查找 intent；`CodeEditorView` 负责更新 `findState`

selection matches 的规则建议写成纯值函数，放到 `CodeEditorViewModel`：

- 仅当当前选区非空、单行、长度在 2...120 之间、去掉空白后仍有内容时启用
- 如果 find bar 当前有非空 query，则 selection matches 仍可保留，但 active find match 优先级高于 selection match，避免样式互相覆盖
- selection matches 的匹配串默认大小写敏感；find query 的大小写敏感度由 `findState.caseSensitive` 决定
- 大文件场景下，find query 改变时允许先做 retained window 范围内同步投影，再异步补齐全量 match count；但首轮实现至少要保证当前可见区装饰立即正确

这一层的关键不是 UI 漂亮，而是状态边界清晰：query 是值、matches 是投影、文本属性应用仍由 `CodeEditorTextView` 执行。

### 3.3 diagnostics underline 范围模型

当前 `LSPDiagnostic` 只有 `line` 与 `character`，不足以表达 underline 的结束位置。建议把 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift` 扩成：

```swift
struct LSPDiagnostic: Codable, Equatable, Sendable {
    let message: String
    let severity: LSPDiagnosticSeverity
    let source: String?
    let line: Int?
    let character: Int?
    let endLine: Int?
    let endCharacter: Int?
}
```

然后在 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift` 的 publishDiagnostics 解析中读取协议 `range.end`。回退规则必须明确：

- 如果语言服务器给了完整 `start/end`，直接按它构造 underline span
- 如果只有起点没有终点，保守降级为单字符 underline
- 如果连起点都没有，则不生成 underline，只保留现有按行 diagnostics summary

不要在本 Feature 发明“自动按单词扩展 diagnostics range”的智能算法。那属于额外猜测，容易让 underline 和服务端真实语义错位。

### 3.4 line-scoped invalidation 与局部属性合并

这是本 Feature 的核心。当前 `CodeEditorHighlightPipeline` 仍以单个 `replacementRange + attributedString` 为结果，Feature 7 建议把它改成逐行 fragment 输出，例如：

```swift
struct CodeEditorStyledLineFragment: @unchecked Sendable {
    let line: Int
    let utf16Range: NSRange
    let attributedString: NSAttributedString
    let fingerprint: Int
}

struct CodeEditorHighlightResult: @unchecked Sendable {
    let version: Int
    let lineFragments: [CodeEditorStyledLineFragment]
}
```

实现思路：

1. `CodeEditorHighlightPipeline.highlight(...)` 仍用 Highlightr 对 retained window 生成语法底稿。
2. 但在返回前把结果按 line 拆成 fragments，并为每行计算一个稳定 fingerprint。
3. `CodeEditorViewModel` 同时给出当前 retained window 的 decoration snapshot。
4. `CodeEditorTextView` / `CodeEditorHighlightApplicator` 合并“syntax attributes + decoration attributes”，但只对 fingerprint 变化或 decoration spans 变化的行做属性回写。
5. 每次应用完成后，把“最近一次已应用的 line fingerprint + decoration fingerprint”缓存到 `CodeEditorPlatformTextView`，下一次只比较 changed lines。

这里的关键约束是：装饰层变化不能迫使整段 retained window 重新 `setAttributes(baseAttributes, range:)`。正确做法是仅对 changed line ranges 先恢复 base attrs，再局部叠加 syntax attrs 和 decoration attrs。

### 3.5 查找栏与编辑器交互

因为仓库里还没有当前文档搜索状态，Feature 7 需要一个最小 find bar。建议新增 `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorFindBar.swift`，并把它放在 `CodeEditorView` 内部文本区域上方。最小行为：

- `Cmd-F` 展开 find bar，并把焦点移到 query 文本框
- `Escape` 在 query 为空时关闭；非空时先清空 query
- `Enter` 跳到下一条 match，`Shift-Enter` 跳到上一条 match
- query 变化后立即刷新当前 retained window 的 find matches，并更新 match count

这里不要把 find bar 放到全局工作台 toolbar，也不要让 `WorkspaceState` 承担 editor-local query 状态。Feature 7 的目标是验证局部装饰与局部属性回写；把查找状态塞成全局只会扩大耦合面。

### 3.6 样式优先级

装饰样式建议固定优先级，避免语法色和装饰互相覆盖得不可预测：

1. `activeFindMatch`
2. `findMatch`
3. `selectionMatch`
4. `diagnosticUnderline`
5. syntax highlight base attrs

含义是：

- find / selection match 主要覆盖 background 或轻量 stroke，不应抹掉 syntax 的 foregroundColor
- diagnostics 只增加 underline 相关 attributes，不覆盖 syntax foregroundColor 或背景高亮
- active find match 可以在普通 find match 之上额外加更高对比度背景或边框，但仍不应改动字体和选区

如果实现时发现 AppKit 的 temporary attributes 更适合 diagnostics underline，可以局部采用，但仍要保持“按 changed line 清理和重建”这一契约，而不是在整份 storage 上全局 sweep。

## 4. 目标文件集

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDecorationModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorFindBar.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsParsingTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorHighlightPipelineTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

### Optional modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorStatusBar.swift`
  只有在执行时决定把 match count 或 case-sensitive 开关放进状态栏，而不是 find bar 自身，才需要修改；首轮优先不动它。
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/FileEditorView.swift`
  只有在 find state 需要跨文件保留，或者执行时发现宿主层必须额外协调 editor focus，才修改；首轮不建议把 editor-local find state 提升到文件宿主层。

## 5. 任务拆解

### Task 1: 先锁定装饰投影与诊断范围模型

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/CodeEditorDecorationModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LSPDiagnosticsSnapshot.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsParsingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`

**Step 1: Write the failing tests**

先把纯值契约钉住，至少覆盖：

- 非空 query 能投影当前文档 match spans
- selection matches 只在单行、非空、非纯空白选区时出现
- diagnostics underline span 会优先使用 `endLine/endCharacter`
- 缺少 end range 时会保守降级为单字符 underline

示例：

```swift
@Test
func selectionMatchesIgnoreMultilineOrWhitespaceSelections() {
    let document = CodeEditorDocument(
        text: "token alpha token\nnext line",
        persistedText: ""
    )

    let whitespaceOnly = CodeEditorViewModel.selectionMatchSnapshot(
        document: document,
        selectedRange: NSRange(location: 5, length: 1),
        visibleLineRange: 1...2
    )

    #expect(whitespaceOnly.spansByLine.isEmpty)
}

@Test
func diagnosticsUnderlineUsesExplicitEndRangeWhenAvailable() {
    let snapshot = LSPDiagnosticsSnapshot(
        workspaceRoot: "/tmp",
        uri: "file:///tmp/Sample.swift",
        diagnostics: [
            .init(
                message: "problem",
                severity: .warning,
                line: 0,
                character: 4,
                endLine: 0,
                endCharacter: 9
            )
        ],
        documentVersion: 3
    )

    let decorations = CodeEditorViewModel.diagnosticUnderlineSnapshot(
        diagnostics: snapshot,
        document: CodeEditorDocument(text: "let value = 1", persistedText: ""),
        visibleLineRange: 1...1
    )

    #expect(decorations.spansByLine[1]?.first?.utf16Range == NSRange(location: 4, length: 5))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-task1 -only-testing:agentGuiTests/CodeEditorViewModelTests -only-testing:agentGuiTests/LSPDiagnosticsParsingTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报缺少 `CodeEditorDecorationModels`、缺少 diagnostics end range 字段或投影 helper 尚不存在。

**Step 3: Write the minimal implementation**

- 新增 `CodeEditorDecorationModels.swift`
- 在 `CodeEditorViewModel` 里加入纯值 helper，例如：

```swift
static func findMatchSnapshot(
    document: CodeEditorDocument,
    findState: CodeEditorFindState,
    visibleLineRange: ClosedRange<Int>
) -> CodeEditorDecorationSnapshot

static func selectionMatchSnapshot(
    document: CodeEditorDocument,
    selectedRange: NSRange,
    visibleLineRange: ClosedRange<Int>
) -> CodeEditorDecorationSnapshot

static func diagnosticUnderlineSnapshot(
    diagnostics: LSPDiagnosticsSnapshot?,
    document: CodeEditorDocument,
    visibleLineRange: ClosedRange<Int>
) -> CodeEditorDecorationSnapshot
```

- 扩展 `LSPDiagnostic`，新增 `endLine/endCharacter`

**Step 4: Run test to verify it passes**

重复上面的 `xcodebuild test` 命令。

Expected: PASS，纯值投影和 diagnostics range fallback 全部通过。

**Step 5: Commit**

```bash
git add agentGui/Models/CodeEditorDecorationModels.swift agentGui/ViewModels/CodeEditorViewModel.swift agentGui/Models/LSPDiagnosticsSnapshot.swift agentGuiTests/CodeEditorViewModelTests.swift agentGuiTests/LSPDiagnosticsParsingTests.swift
git commit -m "feat: add code editor decoration models"
```

### Task 2: 补最小 find bar 与编辑器级查找状态

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorFindBar.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing tests**

至少锁定以下行为：

- `Cmd-F` 会展开 find bar
- 输入 query 后会把 `findState.query` 回写给 `CodeEditorView`
- `Escape` 在空 query 下关闭 find bar
- `Enter` / `Shift-Enter` 能在 matches 之间切换 `selectedMatchIndex`
- find bar 展开与收起不会触发用户文本变更或 LSP change set

示例：

```swift
@MainActor
@Test
func commandFFromTextViewPresentsFindBarWithoutEditingDocument() {
    let harness = CodeEditorViewHarness(initialText: "alpha beta alpha", persistedText: "alpha beta alpha")

    harness.sendFindShortcut()

    #expect(harness.isFindBarPresented)
    #expect(harness.forwardedChanges.isEmpty)
}

@MainActor
@Test
func escapeClosesFindBarWhenQueryIsEmpty() {
    let harness = CodeEditorViewHarness(initialText: "alpha", persistedText: "alpha")
    harness.presentFindBar()
    harness.setFindQuery("")

    harness.sendEscape()

    #expect(harness.isFindBarPresented == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-task2 -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报缺少 find bar、缺少查找 intent 或测试 harness 还不能驱动这些交互。

**Step 3: Write the minimal implementation**

建议新增一个 editor-local find intent，不必和 LSP semantic intent 混在一起：

```swift
enum CodeEditorFindIntent: Equatable, Sendable {
    case present
    case dismiss
    case nextMatch
    case previousMatch
}
```

实现要点：

- `CodeEditorView` 持有 `findState` 与 `visibleLineRange`
- `CodeEditorFindBar` 只负责 query 编辑与按钮，不直接操作 `NSTextView`
- `CodeEditorPlatformTextView.performKeyEquivalent(_:)` 负责把快捷键翻译成 find intent
- `CodeEditorView` 消费 intent，更新 `findState`

**Step 4: Run test to verify it passes**

重复 Task 2 的 `xcodebuild test` 命令。

Expected: PASS，find bar 状态流通过且不产生伪造文本修改。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorFindBar.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorViewIntegrationTests.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "feat: add code editor local find bar"
```

### Task 3: 把语法高亮结果改成逐行 fragment，并实现装饰合并

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Editor/CodeEditorHighlightPipeline.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorHighlightPipelineTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`

**Step 1: Write the failing tests**

先锁定 minimal invalidation 契约，而不是直接写 UI。至少覆盖：

- retained window 高亮结果会被拆成按行 fragments
- decoration-only 变化时，只会重新应用 changed lines
- 应用局部 attributes 后，未变化行的 attributes 指纹保持不变
- 局部回写不会丢选区、typingAttributes 或 marked text 状态

示例：

```swift
@MainActor
@Test
func decorationOnlyChangeReappliesAffectedLinesOnly() {
    let harness = CodeEditorTextViewHarness(text: "alpha beta\nalpha gamma\nomega")

    harness.applyFindQuery("alpha")
    let before = harness.attributeFingerprintByLine()

    harness.applyFindQuery("omega")
    let after = harness.attributeFingerprintByLine()

    #expect(before[1] != after[1])
    #expect(before[2] != after[2])
    #expect(before[3] != after[3])
    #expect(harness.lastReappliedLines == [1, 2, 3])
}
```

如果 harness 里能直接断言“没有动第 N 行”，那就优先断言精确 changed lines，而不是只比对指纹。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-task3 -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报 `CodeEditorHighlightResult` 仍是整块结果，或者 applicator 还没有按行差异应用。

**Step 3: Write the minimal implementation**

建议把 `CodeEditorHighlightResult` 改成 line fragments，并让 applicator 按行工作：

```swift
struct CodeEditorStyledLineFragment: @unchecked Sendable {
    let line: Int
    let utf16Range: NSRange
    let attributedString: NSAttributedString
    let fingerprint: Int
}

@MainActor
enum CodeEditorHighlightApplicator {
    static func apply(
        fragments: [CodeEditorStyledLineFragment],
        decorations: CodeEditorDecorationSnapshot,
        to textView: CodeEditorPlatformTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> Set<Int>
}
```

实现要点：

- `CodeEditorPlatformTextView` 缓存最近一次已应用的 line fingerprints
- 只对 changed lines 先恢复 base attrs，再叠加 syntax attrs 与 decoration attrs
- diagnostics underline 推荐通过 attributes 叠加完成；若必须用 temporary attributes，也要按 changed lines 清理与重建

**Step 4: Run test to verify it passes**

重复 Task 3 的 `xcodebuild test` 命令。

Expected: PASS，fragment 拆分与局部属性回写契约成立。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorHighlightPipeline.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGuiTests/CodeEditorHighlightPipelineTests.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift
git commit -m "refactor: apply code editor highlights per line fragment"
```

### Task 4: 把 find matches、selection matches 和 diagnostics underline 接到可见区装饰管线

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/CodeEditorViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/CodeEditor/CodeEditorTextView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/LSP/LSPClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewModelTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPDiagnosticsParsingTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing tests**

这一轮锁定真正的 Feature 7 验收面：

- query 改变时只影响包含旧/新 matches 的行
- 选中单词时，会为当前 retained window 内的相同词生成 selection matches
- diagnostics 刷新时，只重建受影响行的 underline
- query 清空后，find decorations 会被移除，但 syntax attrs 保持不变

示例：

```swift
@MainActor
@Test
func clearingFindQueryRemovesOnlyFindDecorations() {
    let harness = CodeEditorViewHarness(initialText: "foo bar foo", persistedText: "foo bar foo")
    harness.presentFindBar()
    harness.setFindQuery("foo")

    let highlightedBefore = harness.decoratedLines()

    harness.setFindQuery("")

    #expect(highlightedBefore == [1])
    #expect(harness.decoratedLines().isEmpty)
    #expect(harness.syntaxHighlightStillPresent(onLine: 1))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-task4 -only-testing:agentGuiTests/CodeEditorViewModelTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/LSPDiagnosticsParsingTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，报 find / selection / diagnostics 装饰还没有统一接到当前可见区装饰快照里。

**Step 3: Write the minimal implementation**

- `CodeEditorView` 把 `findState + visibleLineRange + diagnostics + selectedRange` 汇总成交给 `CodeEditorViewModel`
- `CodeEditorTextView` 在 `publishSelection`、`publishVisibleLineRange`、query 改变和 diagnostics 刷新时触发 decoration refresh
- `LSPClient` 完成 diagnostics end range 的协议解析
- query 清空或选区失效时，生成空 decoration snapshot，而不是强制重刷整块 retained window

**Step 4: Run test to verify it passes**

重复 Task 4 的 `xcodebuild test` 命令。

Expected: PASS，Feature 7 的三类装饰都进入统一 snapshot，并且 old/new changed lines 的局部回写生效。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/CodeEditorViewModel.swift agentGui/Views/CodeEditor/CodeEditorView.swift agentGui/Views/CodeEditor/CodeEditorTextView.swift agentGui/Services/LSP/LSPClient.swift agentGuiTests/CodeEditorViewModelTests.swift agentGuiTests/LSPDiagnosticsParsingTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "feat: add code editor search and diagnostic decorations"
```

### Task 5: 跑聚焦回归并补大文件保护断言

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorHighlightPipelineTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorTextViewIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/CodeEditorViewIntegrationTests.swift`

**Step 1: Write the failing tests**

补最后一组保护性回归：

- 大文件阈值下，find / selection decorations 仍只对 retained window 生效，不触发全量属性应用
- 输入法组合态期间不会应用 diagnostics underline 或 find decorations
- reveal / hover / references 现有行为不因 Feature 7 退化

示例：

```swift
@MainActor
@Test
func compositionStateSuppressesDecorationApplication() {
    let harness = CodeEditorTextViewHarness(text: "alpha beta alpha")
    harness.beginMarkedTextComposition()

    harness.applyFindQuery("alpha")

    #expect(harness.lastReappliedLines.isEmpty)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-task5 -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，如果实现里还在 composition / large file 场景下无条件重建装饰，这组回归会把问题暴露出来。

**Step 3: Write the minimal implementation**

- 复用现有 `CodeEditorHighlightPipeline.shouldSkipRealtimeHighlight(...)` 或同级阈值，给 decoration refresh 增加相同的 retained-window 限制
- 在 marked text、程序性 reveal 和外部文本同步路径里跳过 decoration apply
- 跑一轮现有 Feature 6 聚焦测试，确认语义交互未退化

**Step 4: Run test to verify it passes**

先跑 Task 5 的聚焦测试，再补一轮现有回归：

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-feature7-regression -only-testing:agentGuiTests/CodeEditorHighlightPipelineTests -only-testing:agentGuiTests/CodeEditorTextViewIntegrationTests -only-testing:agentGuiTests/CodeEditorViewIntegrationTests -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS，Feature 7 的装饰层不破坏 Feature 6 的语义交互，也不在大文件 / IME 场景下退回粗暴重刷。

**Step 5: Commit**

```bash
git add agentGuiTests/CodeEditorHighlightPipelineTests.swift agentGuiTests/CodeEditorTextViewIntegrationTests.swift agentGuiTests/CodeEditorViewIntegrationTests.swift
git commit -m "test: harden code editor decoration regressions"
```

## 6. 验收清单

满足以下条件时，可以认为 Feature 7 达标：

- 当前文档查找 query 变化后，编辑器能显示 find matches，并具备最小 find bar 交互。
- 选中单词时，当前 retained window 内的同词匹配会被高亮，且不会错误命中空白、多行或超长选区。
- diagnostics 能以下划线而不是整行染色的方式显示，并且只更新受影响行。
- 装饰层变化时不会整段覆盖 attributed text；局部属性回写仅发生在 changed lines 或 changed ranges。
- 现有 hover / definition / references、当前行高亮、gutter 和状态栏行为不退化。

## 7. 推荐执行顺序

建议严格按以下顺序推进：

1. Task 1
2. Task 2
3. Task 3
4. Task 4
5. Task 5

原因：

- 没有纯值装饰模型与 diagnostics range，后续任何 underline 或 find 高亮都只能写成 UI 特判。
- 没有 find bar 状态，当前文档查找就没有可信输入源。
- 没有逐行 fragment 和局部 applicator，Feature 7 的“最小失效渲染”就无法真正验证。

Plan complete and saved to `docs/plans/2026-03-30-code-editor-feature-7-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - 我按 Task 顺序逐个实现、逐个验证

**2. Parallel Session (separate)** - 新开会话按 executing-plans skill 并行执行

**Which approach?**