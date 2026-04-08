# Feature 19: Code Completion 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 代码编辑器实现 LSP 驱动的代码补全面板——用户输入时触发 `textDocument/completion` 请求，浮动面板展示候选项，⬆⬇ 选择，Tab/Enter 插入，Esc 取消，150ms 去抖、代际取消防止旧结果污染。

**Architecture:** 采用与 VS Code SuggestModel/SuggestController 对齐的三层分离：`CodeEditorCompletionTrigger`（触发&状态机，类比 SuggestModel）→ `CodeEditorLSPCoordinator.requestCompletion` （LSP 通信，已有文件扩展）→ `CodeEditorCompletionPanel`（浮动 NSPanel 渲染，类比 SuggestWidget）。所有触发状态通过 `CodeEditorTextView.Coordinator` 桥接，完全 `@MainActor` 安全。

**Tech Stack:** Swift 6 + AppKit (NSPanel, NSTableView) + LSP textDocument/completion, Swift Testing framework

---

## VS Code 关键设计参照

从 `suggestModel.ts` / `suggestController.ts` / `suggestWidget.ts` 提炼的核心决策：

| VS Code 概念 | agentGui 映射 |
|---|---|
| `SuggestModel._triggerQuickSuggest` (TimeoutTimer) | `CodeEditorCompletionTrigger.debounceTask` (Task + sleep) |
| `SuggestModel._requestToken` (CancellationTokenSource) | `CodeEditorCompletionTrigger.completionGeneration: Int` |
| `SuggestModel.trigger(options:)` | `CodeEditorCompletionTrigger.handleTyping(char:position:)` |
| `SuggestModel._onNewContext` refilter | `CodeEditorCompletionTrigger` client-side prefix 过滤 |
| `LineContext.shouldAutoTrigger` (word boundary check) | `CompletionTriggerContext.shouldAutoTrigger` |
| `editorIsComposing` flag | `CodeEditorTextView.Coordinator.isInIMEComposition` |
| `SuggestWidget` (ContentWidget + List) | `CodeEditorCompletionPanel` (NSPanel + NSTableView) |
| `SnippetController.insert(overwriteBefore/After)` | `insertCompletion(_:into:)` overwrite prefix logic |
| trigger character from server capabilities | `LSPServerCapabilityHints.completionTriggerCharacters` (已有) |
| `CompletionTriggerKind.TriggerCharacter / Invoke` | `LSPCompletionTriggerKind` enum |

**关键差异（agentGui vs VSCode）：**
- 无 `CompletionModel` 客户端评分/排序层（首轮直接展示服务端返回顺序，前缀过滤用简单 `hasPrefix`）
- 无多语言 provider 分组；只有一个 LSP server per file
- 面板用 AppKit `NSPanel`，不用 browser DOM ContentWidget
- Snippet 支持：首轮只处理 `insertTextFormat == plainText` 和基础 `$0` 光标占位

---

## 文件清单

| 操作 | 路径 |
|---|---|
| 新增 | `agentGui/Models/CodeEditorCompletionModels.swift` |
| 新增 | `agentGui/Services/Editor/CodeEditorCompletionTrigger.swift` |
| 新增 | `agentGui/Views/CodeEditor/CodeEditorCompletionPanel.swift` |
| 修改 | `agentGui/Services/LSP/LSPClient.swift` (新增 `completion` 方法) |
| 修改 | `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift` (新增 `requestCompletion`) |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorTextView.swift` (触发+面板集成) |
| 修改 | `agentGui/Views/CodeEditor/CodeEditorView.swift` (透传 completionEnabled 参数) |
| 新增测试 | `agentGuiTests/CodeEditorCompletionTriggerTests.swift` |
| 新增测试 | `agentGuiTests/CodeEditorCompletionInsertionTests.swift` |

---

## Task 1: 数据模型 — CodeEditorCompletionModels

**Files:**
- Create: `agentGui/Models/CodeEditorCompletionModels.swift`
- Test: `agentGuiTests/CodeEditorCompletionTriggerTests.swift`（在后续 task 中复用）

### Step 1: 创建模型文件

```swift
// agentGui/Models/CodeEditorCompletionModels.swift
import Foundation

/// 对应 LSP CompletionItem.kind
enum LSPCompletionItemKind: Int, Sendable {
    case text = 1, method, function, constructor, field
    case variable, `class`, interface, module, property
    case unit, value, `enum`, keyword, snippet
    case color, file, reference, folder, enumMember
    case constant, `struct`, event, `operator`, typeParameter
}

/// 对应 LSP CompletionItem.insertTextFormat
enum LSPInsertTextFormat: Int, Sendable {
    case plainText = 1
    case snippet = 2
}

/// 触发类型，对应 LSP CompletionTriggerKind
enum LSPCompletionTriggerKind: Int, Sendable {
    case invoked = 1            // Ctrl+Space / 手动
    case triggerCharacter = 2   // 用户键入了 triggerCharacter（如 ".", ":"）
    case triggerForIncomplete = 3
}

/// 一条 LSP CompletionItem 的本地表示
struct CodeEditorCompletionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String          // 展示标签（label from LSP）
    let detail: String?        // 右侧暗色补充文字（detail from LSP）
    let documentation: String? // 展开文档（documentation.value from LSP）
    let kind: LSPCompletionItemKind?
    let insertText: String     // 实际插入文本（insertText ?? label）
    let insertTextFormat: LSPInsertTextFormat // plainText(1) | snippet(2)
    let filterText: String     // 用于客户端前缀过滤（filterText ?? label）

    init(
        id: UUID = UUID(),
        label: String,
        detail: String? = nil,
        documentation: String? = nil,
        kind: LSPCompletionItemKind? = nil,
        insertText: String? = nil,
        insertTextFormat: LSPInsertTextFormat = .plainText,
        filterText: String? = nil
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.insertText = insertText ?? label
        self.insertTextFormat = insertTextFormat
        self.filterText = filterText ?? label
    }
}

/// 一次补全会话的状态快照（不可变，便于传给 Panel 渲染）
struct CodeEditorCompletionSession: Equatable, Sendable {
    /// 请求时的光标 utf16 偏移
    let cursorOffset: Int
    /// 已键入的前缀词（用于 overwriteBefore 计算）
    let prefixWord: String
    /// 经前缀过滤后的候选项（最多 viewLimit 条）
    let items: [CodeEditorCompletionItem]
    /// 当前选中索引
    let selectedIndex: Int
    /// 是否正在加载
    let isLoading: Bool

    static let loading = CodeEditorCompletionSession(
        cursorOffset: 0,
        prefixWord: "",
        items: [],
        selectedIndex: 0,
        isLoading: true
    )

    func withSelectedIndex(_ index: Int) -> CodeEditorCompletionSession {
        CodeEditorCompletionSession(
            cursorOffset: cursorOffset,
            prefixWord: prefixWord,
            items: items,
            selectedIndex: max(0, min(index, items.count - 1)),
            isLoading: isLoading
        )
    }
}

/// 触发上下文（类比 VSCode LineContext）
struct CompletionTriggerContext: Sendable {
    let cursorOffset: Int       // utf16 offset in full document
    let prefixWord: String      // word fragment before cursor (e.g. "myFu")
    let triggerKind: LSPCompletionTriggerKind
    let triggerCharacter: String? // only set when triggerKind == .triggerCharacter

    /// 是否满足自动触发条件：光标末尾有至少 1 个非数字词字符
    /// 对应 VSCode LineContext.shouldAutoTrigger
    static func shouldAutoTrigger(prefixWord: String) -> Bool {
        guard !prefixWord.isEmpty else { return false }
        // 不为纯数字
        if prefixWord.allSatisfy({ $0.isNumber }) { return false }
        return true
    }
}
```

### Step 2: 确认文件编译通过

在 Xcode 中 Cmd+B，确认 0 errors。

---

## Task 2: LSPClient — 新增 textDocument/completion 请求

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`
- Test: 在 Task 6 测试中通过 harness 验证

### Step 1: 编写失败测试（先在注释中）

测试目标：`LSPClient.completion(uri:line:character:triggerKind:triggerCharacter:)` 返回 `[CodeEditorCompletionItem]`，涉及 LSP transport mock，放在 Task 6 一并覆盖。

### Step 2: 在 LSPClient 中添加 completion 方法

定位 `hover(uri:line:character:)` 方法之后，新增：

```swift
/// 发送 textDocument/completion 请求并解析返回的补全项列表。
/// - Returns: 解析后的补全项数组；网络或解析失败时返回空数组（不 throw）。
func completion(
    uri: String,
    line: Int,
    character: Int,
    triggerKind: LSPCompletionTriggerKind,
    triggerCharacter: String?
) async -> [CodeEditorCompletionItem] {
    var context: [String: Any] = ["triggerKind": triggerKind.rawValue]
    if let tc = triggerCharacter {
        context["triggerCharacter"] = tc
    }
    let params: [String: Any] = [
        "textDocument": ["uri": uri],
        "position": ["line": line, "character": character],
        "context": context
    ]
    guard let result = try? await transport.sendRequest(
        method: "textDocument/completion",
        params: params
    ) else { return [] }
    return parseCompletionItems(from: result)
}
```

### Step 3: 新增私有解析方法

在 LSPClient 的 `// MARK: - Parsing` 区域（或文件末尾）添加：

```swift
private func parseCompletionItems(from result: Any?) -> [CodeEditorCompletionItem] {
    // LSP 返回 CompletionList | CompletionItem[] | null
    let rawItems: [[String: Any]]
    if let list = result as? [String: Any],
       let items = list["items"] as? [[String: Any]] {
        rawItems = items               // CompletionList
    } else if let items = result as? [[String: Any]] {
        rawItems = items               // CompletionItem[]
    } else {
        return []
    }

    return rawItems.compactMap { item -> CodeEditorCompletionItem? in
        guard let label = item["label"] as? String else { return nil }
        let detail = item["detail"] as? String
        let insertText = item["insertText"] as? String
        let filterText = item["filterText"] as? String
        let kindRaw = item["kind"] as? Int
        let formatRaw = (item["insertTextFormat"] as? Int) ?? 1
        let documentationRaw = item["documentation"]
        let documentation: String?
        if let s = documentationRaw as? String {
            documentation = s
        } else if let d = documentationRaw as? [String: Any],
                  let value = d["value"] as? String {
            documentation = value
        } else {
            documentation = nil
        }
        return CodeEditorCompletionItem(
            label: label,
            detail: detail,
            documentation: documentation,
            kind: kindRaw.flatMap { LSPCompletionItemKind(rawValue: $0) },
            insertText: insertText,
            insertTextFormat: LSPInsertTextFormat(rawValue: formatRaw) ?? .plainText,
            filterText: filterText
        )
    }
}
```

### Step 4: Xcode Cmd+B，0 errors

---

## Task 3: CodeEditorLSPCoordinator — 新增 requestCompletion

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`

> **现有代码背景：** `CodeEditorLSPCoordinator` 已有 `requestHover(at:)` 方法（含代际取消），`requestCompletion` 完全对称实现。

### Step 1: 在 coordinator 中声明新的 generation 变量

在现有 `private var latestHoverGeneration = 0` 之后添加：

```swift
private var completionGeneration = 0
private var pendingCompletionTask: Task<Void, Never>?
```

### Step 2: 添加 requestCompletion 方法

放在 `requestHover(at:)` 之后：

```swift
/// 请求 LSP 代码补全。
/// - Parameters:
///   - context: 触发上下文（含光标位置、触发类型）
///   - onResult: 主线程回调，收到结果或取消时调用。
///     items 为 nil 表示被取消（新请求到达）。
func requestCompletion(
    context: CompletionTriggerContext,
    onResult: @MainActor @escaping ([CodeEditorCompletionItem]?) -> Void
) {
    guard isOpen else { return }
    completionGeneration &+= 1
    let generation = completionGeneration
    pendingCompletionTask?.cancel()
    pendingCompletionTask = Task { [weak self] in
        guard let self else { return }
        let position = self.lspPosition(forUTF16Offset: context.cursorOffset)
        let items = await self.manager.client(
            workspaceRoot: self.binding.workspaceRoot,
            serverID: self.binding.serverID
        )?.completion(
            uri: self.binding.uri,
            line: position.line,
            character: position.character,
            triggerKind: context.triggerKind,
            triggerCharacter: context.triggerCharacter
        ) ?? []
        guard !Task.isCancelled, self.completionGeneration == generation else {
            await onResult(nil) // 已被取代
            return
        }
        await onResult(items)
    }
}

func cancelCompletion() {
    pendingCompletionTask?.cancel()
    pendingCompletionTask = nil
}
```

### Step 3: 添加 lspPosition 辅助方法（如尚未存在）

检查文件是否已有 `lspPosition(forUTF16Offset:)` 。若无，在 `// MARK: - Helpers` 区域添加：

```swift
/// 将 utf16 偏移转换为 LSP Position (line, character)。
/// 复用 CodeEditorDocument 的行索引逻辑，保持版本一致。
private func lspPosition(forUTF16Offset offset: Int) -> (line: Int, character: Int) {
    guard let client = manager.client(
        workspaceRoot: binding.workspaceRoot,
        serverID: binding.serverID
    ), let snapshot = client.documentStore.snapshot(uri: binding.uri) else {
        return (0, 0)
    }
    return snapshot.lspPosition(forUTF16Offset: offset)
}
```

> **注意：** 如果 `LSPDocumentSnapshot` 还没有 `lspPosition(forUTF16Offset:)` 方法，在 `LSPDocumentSnapshot` 上添加如下扩展（确认 snapshot 已 expose `documentStore`）。

### Step 4: Xcode Cmd+B，0 errors

---

## Task 4: CodeEditorCompletionTrigger — 触发状态机

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorCompletionTrigger.swift`
- Test: `agentGuiTests/CodeEditorCompletionTriggerTests.swift`

> **VSCode 参照：** 对应 `SuggestModel` 的职责——去抖、trigger character检测、代际取消、客户端前缀重过滤。

### Step 1: 先写测试文件（TDD）

```swift
// agentGuiTests/CodeEditorCompletionTriggerTests.swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorCompletionTriggerTests {

    // MARK: - shouldAutoTrigger

    @Test func shouldAutoTrigger_nonEmptyNonNumericWord_returnsTrue() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "myFun") == true)
    }

    @Test func shouldAutoTrigger_emptyString_returnsFalse() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "") == false)
    }

    @Test func shouldAutoTrigger_pureNumber_returnsFalse() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "123") == false)
    }

    // MARK: - trigger character detection

    @Test func triggerCharDetected_whenTypedDot_returnsTriggerCharKind() {
        let triggerChars = ["."]
        let lastChar = "."
        let isTrigger = triggerChars.contains(lastChar)
        #expect(isTrigger == true)
    }

    @Test func triggerCharNotDetected_whenTypedLetter_returnsInvokedKind() {
        let triggerChars = ["."]
        let lastChar = "f"
        let isTrigger = triggerChars.contains(lastChar)
        #expect(isTrigger == false)
    }

    // MARK: - client-side prefix refilter

    @Test func prefixRefilter_returnsItemsMatchingPrefix() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "myFunction"),
            CodeEditorCompletionItem(label: "myVariable"),
            CodeEditorCompletionItem(label: "otherFunc"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "my")
        #expect(filtered.map(\.label) == ["myFunction", "myVariable"])
    }

    @Test func prefixRefilter_emptyPrefix_returnsAll() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "a"),
            CodeEditorCompletionItem(label: "b"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "")
        #expect(filtered.count == 2)
    }

    @Test func prefixRefilter_caseInsensitive() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "PrintLine"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "print")
        #expect(filtered.count == 1)
    }
}
```

### Step 2: 运行测试，确认它们 FAIL（新文件不存在）

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f19-t1 \
  -only-testing:agentGuiTests/CodeEditorCompletionTriggerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

期望：FAIL（compilation error，CodeEditorCompletionTrigger 不存在）

### Step 3: 实现 CodeEditorCompletionTrigger

```swift
// agentGui/Services/Editor/CodeEditorCompletionTrigger.swift
import Foundation
import AppKit

/// 管理代码补全触发状态机。
/// 对应 VSCode SuggestModel 的职责：
///   - 去抖（150ms），防止快速输入时频繁发起 LSP 请求
///   - trigger character 立即触发（不去抖）
///   - 代际取消：新触发到来时取消旧请求
///   - 客户端前缀重过滤：补全会话打开时追加输入只需本地过滤
@MainActor
final class CodeEditorCompletionTrigger {
    // MARK: - Configuration
    static let debounceNanoseconds: UInt64 = 150_000_000 // 150ms
    static let maxItems = 100 // 列表最多展示条数

    // MARK: - State
    private var debounceTask: Task<Void, Never>?
    private var cachedAllItems: [CodeEditorCompletionItem] = []  // 最近一次 LSP 结果全集
    private var lastFetchPrefixWord = ""                          // 发起请求时的前缀
    private(set) var currentSession: CodeEditorCompletionSession? // nil = 面板关闭

    // MARK: - Callbacks
    var onSessionChange: ((CodeEditorCompletionSession?) -> Void)?

    // MARK: - Dependencies (injected)
    var requestCompletion: ((CompletionTriggerContext, @escaping ([CodeEditorCompletionItem]?) -> Void) -> Void)?
    var cancelRequest: (() -> Void)?

    // MARK: - Public API

    /// 用户键入字符后调用。
    /// - Parameters:
    ///   - char: 刚输入的字符（单个 Unicode Scalar string）
    ///   - cursorOffset: 当前光标 utf16 偏移
    ///   - prefixWord: 光标前的当前词（如 "myFu"）
    ///   - triggerCharacters: 来自 server capabilities 的 trigger characters
    func handleTyping(
        char: String,
        cursorOffset: Int,
        prefixWord: String,
        triggerCharacters: [String]
    ) {
        // IME 组合输入期间不触发（调用方负责在 hasMarkedText 时不调用此方法）
        // Trigger character: 立即触发，不去抖
        if triggerCharacters.contains(char) {
            debounceTask?.cancel()
            debounceTask = nil
            scheduleFetch(
                context: CompletionTriggerContext(
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char
                )
            )
            return
        }

        // 若已有会话打开，尝试客户端重过滤（对应 VSCode _onNewContext refilter）
        if currentSession != nil, !cachedAllItems.isEmpty {
            let filtered = Self.clientFilter(items: cachedAllItems, prefix: prefixWord)
            if filtered.isEmpty {
                // 过滤后为空：关闭面板（同 VSCode cancel when word becomes empty）
                dismiss()
            } else {
                // 有结果：直接更新会话，不重发 LSP 请求
                let updated = CodeEditorCompletionSession(
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    items: Array(filtered.prefix(Self.maxItems)),
                    selectedIndex: 0,
                    isLoading: false
                )
                publishSession(updated)
            }
            // 但仍去抖发起新请求，以刷新完整候选列表（服务端可能有更多）
        }

        // Auto-trigger 去抖
        guard CompletionTriggerContext.shouldAutoTrigger(prefixWord: prefixWord) else {
            if currentSession != nil { dismiss() }
            return
        }
        debounceTask?.cancel()
        let ctx = CompletionTriggerContext(
            cursorOffset: cursorOffset,
            prefixWord: prefixWord,
            triggerKind: .invoked,
            triggerCharacter: nil
        )
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.scheduleFetch(context: ctx)
        }
    }

    /// 用户移动光标（非输入）时调用。
    /// - 若光标离开当前词范围，关闭面板。
    func handleCursorMove(prefixWord: String) {
        guard currentSession != nil else { return }
        if prefixWord.isEmpty {
            dismiss()
        }
    }

    /// Tab / Enter 选中项插入后调用：重置所有状态。
    func confirmed() {
        debounceTask?.cancel()
        debounceTask = nil
        cachedAllItems = []
        lastFetchPrefixWord = ""
        publishSession(nil)
    }

    /// Esc 或失焦时调用。
    func dismiss() {
        debounceTask?.cancel()
        debounceTask = nil
        cancelRequest?()
        cachedAllItems = []
        lastFetchPrefixWord = ""
        publishSession(nil)
    }

    // MARK: - Client-side filter (static, testable)

    /// 客户端前缀过滤（case-insensitive hasPrefix 匹配 filterText）。
    /// 对应 VSCode CompletionModel 的轻量前缀过滤。
    static func clientFilter(
        items: [CodeEditorCompletionItem],
        prefix: String
    ) -> [CodeEditorCompletionItem] {
        guard !prefix.isEmpty else { return items }
        let lower = prefix.lowercased()
        return items.filter { $0.filterText.lowercased().hasPrefix(lower) }
    }

    // MARK: - Private

    private func scheduleFetch(context: CompletionTriggerContext) {
        // 显示 loading 状态（如面板已打开则不新建 loading 会话，避免闪烁）
        if currentSession == nil {
            publishSession(.loading)
        }
        lastFetchPrefixWord = context.prefixWord
        requestCompletion?(context) { [weak self] items in
            guard let self else { return }
            guard let items else {
                // nil = 被代际取消，不更新 UI
                return
            }
            self.cachedAllItems = items
            let filtered = Self.clientFilter(items: items, prefix: context.prefixWord)
            if filtered.isEmpty {
                self.dismiss()
                return
            }
            let session = CodeEditorCompletionSession(
                cursorOffset: context.cursorOffset,
                prefixWord: context.prefixWord,
                items: Array(filtered.prefix(Self.maxItems)),
                selectedIndex: 0,
                isLoading: false
            )
            self.publishSession(session)
        }
    }

    private func publishSession(_ session: CodeEditorCompletionSession?) {
        currentSession = session
        onSessionChange?(session)
    }
}
```

### Step 4: 运行测试，确认 PASS

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f19-t1 \
  -only-testing:agentGuiTests/CodeEditorCompletionTriggerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

期望：`** TEST SUCCEEDED **`

### Step 5: Commit

```
git add agentGui/Models/CodeEditorCompletionModels.swift \
        agentGui/Services/Editor/CodeEditorCompletionTrigger.swift \
        agentGuiTests/CodeEditorCompletionTriggerTests.swift
git commit -m "feat(F19): add completion models and trigger state machine"
```

---

## Task 5: CodeEditorCompletionPanel — 浮动补全面板

**Files:**
- Create: `agentGui/Views/CodeEditor/CodeEditorCompletionPanel.swift`

> **VSCode 参照：** 对应 `SuggestWidget`（State machine: Hidden/Loading/Open）+ `SuggestContentWidget`（ContentWidget 决定 ABOVE/BELOW 光标）。
> **agentGui 实现：** 用 `NSPanel(.borderless, .nonactivatingPanel)` + `NSTableView`；位置锚定在光标矩形下方（或空间不足时上方）。

### Step 1: 实现面板类

```swift
// agentGui/Views/CodeEditor/CodeEditorCompletionPanel.swift
import AppKit

// MARK: - Item Row View

/// 单条补全项的行视图（label + kind icon + detail）。
private final class CompletionItemRowView: NSTableCellView {
    let kindLabel = NSTextField(labelWithString: "")
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        kindLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [kindLabel, nameLabel, detailLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: CodeEditorCompletionItem, isSelected: Bool) {
        kindLabel.stringValue = item.kind.map { kindString($0) } ?? " "
        nameLabel.stringValue = item.label
        detailLabel.stringValue = item.detail ?? ""
        nameLabel.textColor = isSelected ? .selectedControlTextColor : .labelColor
        detailLabel.textColor = isSelected ? .selectedControlTextColor.withAlphaComponent(0.6)
                                           : .secondaryLabelColor
    }

    private func kindString(_ kind: LSPCompletionItemKind) -> String {
        switch kind {
        case .function, .method: return "ƒ"
        case .class, .struct: return "C"
        case .variable, .field: return "v"
        case .keyword: return "K"
        case .snippet: return "⎇"
        case .module: return "M"
        case .property: return "p"
        case .enumMember, .enum: return "E"
        case .interface: return "I"
        case .typeParameter: return "T"
        default: return "·"
        }
    }
}

// MARK: - Panel

/// 浮动补全面板。持有者（CodeEditorTextView.Coordinator）负责定位和更新。
/// 对应 VSCode SuggestWidget 的展示职责。
final class CodeEditorCompletionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let itemHeight: CGFloat = 22
    static let maxVisibleItems = 10
    static let panelWidth: CGFloat = 380

    // MARK: Windowing
    private(set) var panel: NSPanel
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    // MARK: State
    private var items: [CodeEditorCompletionItem] = []
    private var selectedIndex: Int = 0
    var onAccept: ((CodeEditorCompletionItem) -> Void)?
    var onDismiss: (() -> Void)?

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0)
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.animationBehavior = .none

        super.init()

        // Container view with visual effect
        let container = NSVisualEffectView(frame: contentRect)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        panel.contentView = container

        // Table setup
        tableView.headerView = nil
        tableView.rowHeight = Self.itemHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(acceptSelected)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    // MARK: - Public API

    func update(session: CodeEditorCompletionSession) {
        guard !session.isLoading else { return }
        items = session.items
        selectedIndex = session.selectedIndex
        reloadAndResize()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        scrollToSelected()
    }

    func show(anchoredBelow cursorRect: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { return }
        positionPanel(below: cursorRect, in: window)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    func hide() {
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        items = []
    }

    func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        scrollToSelected()
    }

    func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        scrollToSelected()
    }

    func acceptSelectedItem() -> CodeEditorCompletionItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.backgroundColor = .clear
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompletionItemRowView
            ?? CompletionItemRowView(frame: .zero)
        cell.identifier = id
        let isSelected = row == selectedIndex
        cell.configure(item: items[row], isSelected: isSelected)
        cell.wantsLayer = true
        cell.layer?.backgroundColor = isSelected
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        selectedIndex = row
        // 刷新颜色
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    // MARK: - Private

    @objc private func acceptSelected() {
        guard let item = acceptSelectedItem() else { return }
        onAccept?(item)
    }

    private func reloadAndResize() {
        tableView.reloadData()
        let visibleCount = min(items.count, Self.maxVisibleItems)
        let panelHeight = CGFloat(visibleCount) * Self.itemHeight + 4 // top+bottom padding
        var frame = panel.frame
        frame.size = CGSize(width: Self.panelWidth, height: panelHeight)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func positionPanel(below cursorRect: NSRect, in window: NSWindow) {
        let screenCursorRect = window.convertToScreen(cursorRect)
        let visibleCount = min(max(items.count, 1), Self.maxVisibleItems)
        let panelHeight = CGFloat(visibleCount) * Self.itemHeight + 4
        var origin = NSPoint(
            x: screenCursorRect.minX,
            y: screenCursorRect.minY - panelHeight - 2
        )
        // 检查下方空间是否足够，否则显示在光标上方
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.y < screenFrame.minY {
                origin.y = screenCursorRect.maxY + 2
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func scrollToSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        tableView.scrollRowToVisible(selectedIndex)
    }
}
```

### Step 2: Xcode Cmd+B，0 errors

### Step 3: Commit

```
git add agentGui/Views/CodeEditor/CodeEditorCompletionPanel.swift
git commit -m "feat(F19): add completion panel (NSPanel + NSTableView)"
```

---

## Task 6: 插入逻辑测试 — CodeEditorCompletionInsertionTests

**Files:**
- Create: `agentGuiTests/CodeEditorCompletionInsertionTests.swift`

> **VSCode 参照：** `SuggestController.getOverwriteInfo(item:)` 计算 `overwriteBefore / overwriteAfter`，`snippetController.insert(...)` 处理 snippet 格式。

### Step 1: 写失败测试

```swift
// agentGuiTests/CodeEditorCompletionInsertionTests.swift
import Foundation
import Testing
@testable import agentGui

struct CodeEditorCompletionInsertionTests {

    // MARK: - insertCompletion 辅助函数测试

    @Test func plainTextCompletion_replacesPrefix() {
        // "myFu" + 选中 "myFunction" → 文本变为 (原文 - prefix + insertText)
        let text = "let x = myFu"
        let item = CodeEditorCompletionItem(
            label: "myFunction",
            insertText: "myFunction",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count, // cursor 在末尾
            prefixWord: "myFu"
        )
        #expect(result.newText == "let x = myFunction")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }

    @Test func snippetCompletion_replacesPlaceholderAndPositionsCursor() {
        // snippet "print($0)" → 插入后把 $0 替换为空，光标在括号内
        let text = "pr"
        let item = CodeEditorCompletionItem(
            label: "print(_:)",
            insertText: "print($0)",
            insertTextFormat: .snippet
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count,
            prefixWord: "pr"
        )
        #expect(result.newText == "print()")
        // cursor 应在 '(' 之后，即 offset = "print(".count = 6
        #expect(result.newCursorOffset == 6)
    }

    @Test func snippet_withNoPlaceholder_cursorAfterInsertedText() {
        // snippet "import Foundation" (no $0) → cursor 在文本末尾
        let text = "im"
        let item = CodeEditorCompletionItem(
            label: "import Foundation",
            insertText: "import Foundation",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: "im".utf16.count,
            prefixWord: "im"
        )
        #expect(result.newText == "import Foundation")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }

    @Test func completion_withPrefixNotMatchingInsertText_stillInsertsCorrectly() {
        // 触发字符 "." 后 prefixWord="" 但 insertText="show()"
        let text = "window."
        let item = CodeEditorCompletionItem(
            label: "show()",
            insertText: "show()",
            insertTextFormat: .plainText
        )
        let result = CodeEditorCompletionInserter.apply(
            item: item,
            to: text,
            cursorOffset: text.utf16.count,
            prefixWord: ""  // trigger character 后前缀为空
        )
        #expect(result.newText == "window.show()")
        #expect(result.newCursorOffset == result.newText.utf16.count)
    }
}
```

### Step 2: 运行测试，确认 FAIL（CodeEditorCompletionInserter 不存在）

### Step 3: 实现 CodeEditorCompletionInserter

在 `CodeEditorCompletionModels.swift` 文件末尾追加（或单独一个文件）：

```swift
// MARK: - Insertion Result

struct CompletionInsertionResult {
    let newText: String
    let newCursorOffset: Int  // utf16 offset in newText
}

// MARK: - Inserter

/// 纯函数辅助：把补全项应用到文本字符串，返回新文本和新光标位置。
/// 对应 VSCode SuggestController._insertSuggestion 的核心逻辑。
enum CodeEditorCompletionInserter {

    /// 将补全项应用到文本。
    /// - Parameters:
    ///   - item: 选中的补全项
    ///   - text: 当前全文
    ///   - cursorOffset: 当前光标 utf16 偏移
    ///   - prefixWord: 光标前已键入的词前缀（用来计算 overwriteBefore）
    static func apply(
        item: CodeEditorCompletionItem,
        to text: String,
        cursorOffset: Int,
        prefixWord: String
    ) -> CompletionInsertionResult {
        let utf16 = text.utf16
        let overwriteBefore = prefixWord.utf16.count  // 替换光标前 prefixWord 长度的字符
        let replaceStart = max(0, cursorOffset - overwriteBefore)
        let replaceEnd = cursorOffset  // 首轮不做 overwriteAfter（insert mode）

        guard replaceStart <= replaceEnd,
              replaceEnd <= utf16.count else {
            // 越界保护
            return CompletionInsertionResult(newText: text, newCursorOffset: cursorOffset)
        }

        var insertString = item.insertText
        var finalCursorOffset: Int

        switch item.insertTextFormat {
        case .snippet:
            // 首轮 snippet 支持：找到 $0 位置作为光标停止点，去掉 $0 标记
            // $1, ${1:placeholder} 等忽略，直接保留文字部分
            let processed = processSnippet(insertString)
            insertString = processed.text
            // 光标偏移 = replaceStart + $0 在 processed.text 里的 utf16 位置
            finalCursorOffset = replaceStart + processed.cursorPositionInInsertion
        case .plainText:
            finalCursorOffset = replaceStart + insertString.utf16.count
        }

        // 拼接新文本
        let startIndex = utf16.index(utf16.startIndex, offsetBy: replaceStart)
        let endIndex = utf16.index(utf16.startIndex, offsetBy: replaceEnd)
        var newUTF16 = Array(utf16[utf16.startIndex..<startIndex])
        newUTF16 += Array(insertString.utf16)
        newUTF16 += Array(utf16[endIndex...])
        let newText = String(utf16CodeUnits: newUTF16, encoding: .utf16) ?? text

        return CompletionInsertionResult(newText: newText, newCursorOffset: finalCursorOffset)
    }

    // MARK: - Snippet processing (basic: $0 only)

    private struct SnippetProcessedResult {
        let text: String
        let cursorPositionInInsertion: Int  // utf16 in text
    }

    private static func processSnippet(_ snippet: String) -> SnippetProcessedResult {
        // 找到第一个 $0 位置，移除该标记，光标停在此处
        if let range = snippet.range(of: "$0") {
            let before = String(snippet[snippet.startIndex..<range.lowerBound])
            let after = String(snippet[range.upperBound...])
            // 递归处理其他 $N 占位：直接去掉 $ 和数字（粗暴处理）
            let cleaned = (before + after).replacingOccurrences(
                of: #"\$\{?\d+(?::[^}]*)?\}?"#,
                with: "",
                options: .regularExpression
            )
            let cursorPos = before.utf16.count
            return SnippetProcessedResult(text: cleaned, cursorPositionInInsertion: cursorPos)
        }
        // 无 $0：去掉所有 placeholder 标记，光标在末尾
        let cleaned = snippet.replacingOccurrences(
            of: #"\$\{?\d+(?::[^}]*)?\}?"#,
            with: "",
            options: .regularExpression
        )
        return SnippetProcessedResult(text: cleaned, cursorPositionInInsertion: cleaned.utf16.count)
    }
}
```

### Step 4: 运行测试，确认 PASS

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f19-t2 \
  -only-testing:agentGuiTests/CodeEditorCompletionInsertionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAILED|passed"
```

### Step 5: Commit

```
git add agentGuiTests/CodeEditorCompletionInsertionTests.swift
git commit -m "feat(F19): add insertion helper and tests"
```

---

## Task 7: CodeEditorTextView.Coordinator — 集成触发、面板、插入

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`

> **这是最复杂的 Task，需要分三个子步骤。**
> 
> **VSCode 参照：** `SuggestModel` 通过 `onDidType` + `onDidCompositionEnd`检测输入；`SuggestController` 连接键绑定（Tab accept、Escape dismiss、Arrow navigate）。

### Step 7a: Coordinator 中添加 completion 相关状态和依赖注入

在 `Coordinator` 类中，定位 `private var pendingHoverTask` 等实例变量区域，新增：

```swift
// MARK: - Completion
private let completionTrigger = CodeEditorCompletionTrigger()
private var completionPanel: CodeEditorCompletionPanel?
private var isInIMEComposition = false
```

在 `Coordinator.init` 或首次设置 `completionPanel` 的时机（如 `installCompletion(for:coordinator:)` 方法中），注入回调：

```swift
func installCompletion(for textView: CodeEditorPlatformTextView, coordinator: CodeEditorLSPCoordinator?) {
    guard let coordinator else { return }
    let panel = CodeEditorCompletionPanel()
    completionPanel = panel

    // 当面板条目被接受时，执行插入
    panel.onAccept = { [weak self, weak textView] item in
        guard let self, let textView else { return }
        self.acceptCompletion(item: item, in: textView)
    }
    panel.onDismiss = { [weak self] in
        self?.completionTrigger.dismiss()
    }

    // trigger → LSP coordinator 桥接
    completionTrigger.requestCompletion = { [weak coordinator] ctx, callback in
        coordinator?.requestCompletion(context: ctx, onResult: callback)
    }
    completionTrigger.cancelRequest = { [weak coordinator] in
        coordinator?.cancelCompletion()
    }

    // 面板刷新
    completionTrigger.onSessionChange = { [weak self, weak textView, weak panel] session in
        guard let textView, let panel else { return }
        if let session, !session.isLoading, !session.items.isEmpty {
            panel.update(session: session)
            let cursorRect = textView.cursorRect
            if let window = textView.window {
                panel.show(anchoredBelow: window.convertToScreen(
                    textView.convert(cursorRect, to: nil)), in: window)
            }
        } else if session == nil {
            panel.hide()
        }
    }
}
```

### Step 7b: 在 textDidChange 中触发补全

在 `Coordinator.textDidChange` 方法中，找到处理用户输入的分支（`case .userEdit:`），在 `schedulePendingChange` 调用之后追加：

```swift
// F19: Completion trigger
if !textView.hasMarkedText(),
   let lspCoordinator = parent.lspCoordinator,
   let caps = lspCoordinator.capabilities,
   caps.supportsCompletion {
    let cursorOffset = textView.selectedRange().location
    let prefixWord = textView.prefixWordBeforeCursor()
    let lastTyped = textView.lastTypedCharacter ?? ""
    completionTrigger.handleTyping(
        char: lastTyped,
        cursorOffset: cursorOffset,
        prefixWord: prefixWord,
        triggerCharacters: caps.completionTriggerCharacters
    )
}
```

### Step 7c: Tab / Esc / Arrow 键处理

在 `CodeEditorPlatformTextView` 中覆盖 `keyDown(with:)`（或在 Coordinator 的 `textView(_:doCommandBy:)` 里）：

```swift
// 在 CodeEditorPlatformTextView 中（agentGui 已有此类）
override func keyDown(with event: NSEvent) {
    // 只在面板可见时拦截
    guard let completionDelegate, completionDelegate.isCompletionPanelVisible else {
        super.keyDown(with: event)
        return
    }
    switch event.keyCode {
    case 48: // Tab
        completionDelegate.acceptCompletion()
    case 36: // Enter — 可选接受
        completionDelegate.acceptCompletion()
    case 53: // Esc
        completionDelegate.dismissCompletion()
        super.keyDown(with: event)
    case 125: // ↓
        completionDelegate.selectNextCompletion()
    case 126: // ↑
        completionDelegate.selectPrevCompletion()
    default:
        super.keyDown(with: event)
    }
}
```

> **注意：** 需要在 `CodeEditorPlatformTextView` 上声明 `weak var completionDelegate: CompletionKeyDelegate?`，并在 Coordinator 中实现该协议。

定义协议：

```swift
@MainActor
protocol CompletionKeyDelegate: AnyObject {
    var isCompletionPanelVisible: Bool { get }
    func acceptCompletion()
    func dismissCompletion()
    func selectNextCompletion()
    func selectPrevCompletion()
}
```

Coordinator 实现：

```swift
extension CodeEditorTextView.Coordinator: CompletionKeyDelegate {
    var isCompletionPanelVisible: Bool {
        completionPanel?.panel.isVisible ?? false
    }
    func acceptCompletion() {
        guard let item = completionPanel?.acceptSelectedItem(),
              let textView = /* 保存的 textView 弱引用 */ else { return }
        acceptCompletion(item: item, in: textView)
    }
    func dismissCompletion() {
        completionTrigger.dismiss()
    }
    func selectNextCompletion() {
        completionPanel?.selectNext()
    }
    func selectPrevCompletion() {
        completionPanel?.selectPrevious()
    }
}
```

### Step 7d: acceptCompletion 插入实现

```swift
private func acceptCompletion(
    item: CodeEditorCompletionItem,
    in textView: CodeEditorPlatformTextView
) {
    let session = completionTrigger.currentSession
    let prefixWord = session?.prefixWord ?? ""
    let cursorOffset = textView.selectedRange().location
    let currentText = textView.string

    let result = CodeEditorCompletionInserter.apply(
        item: item,
        to: currentText,
        cursorOffset: cursorOffset,
        prefixWord: prefixWord
    )

    // 应用到 NSTextStorage（不记录 undo stop，由 AppKit 统一管理）
    let replaceRange = NSRange(
        location: cursorOffset - prefixWord.utf16.count,
        length: prefixWord.utf16.count
    )
    textView.textStorage?.beginEditing()
    textView.textStorage?.replaceCharacters(
        in: replaceRange,
        with: result.newText.isEmpty ? "" : String(
            result.newText.utf16[
                result.newText.utf16.index(result.newText.utf16.startIndex, offsetBy: replaceRange.location)
                ..< result.newText.utf16.index(result.newText.utf16.startIndex, offsetBy: replaceRange.location + item.insertText.utf16.count)
            ]
        )!
    )
    textView.textStorage?.endEditing()

    // 更简洁的方式：利用 NSTextView 的 insertText，让 AppKit 管理 undo
    if textView.shouldChangeText(in: replaceRange, replacementString: item.insertText) {
        textView.textStorage?.replaceCharacters(in: replaceRange, with: item.insertText)
        textView.didChangeText()
    }
    textView.setSelectedRange(NSRange(location: replaceRange.location + item.insertText.utf16.count, length: 0))
    completionTrigger.confirmed()
}
```

> **注意：** 上面的实现使用 `shouldChangeText + replaceCharacters + didChangeText` 三步，这是 AppKit 推荐的保持 undo 栈正确的方式，和 VSCode 的 `editor.executeEdits` 等效。

### Step 7e: IME composition 处理

在 `Coordinator.handleCompositionStateChange` 方法中（已有），追加：

```swift
isInIMEComposition = textView.hasMarkedText()
if isInIMEComposition {
    completionTrigger.dismiss()
}
```

并在 `completionTrigger.handleTyping` 调用处加入 guard：

```swift
guard !isInIMEComposition, !textView.hasMarkedText() else { return }
```

### Step 7f: NSTextView 辅助方法

如果 `CodeEditorPlatformTextView` 中没有以下方法，添加：

```swift
extension CodeEditorPlatformTextView {
    /// 光标前的当前词（maxLength 限制防止超大行）
    func prefixWordBeforeCursor(maxLength: Int = 200) -> String {
        let offset = selectedRange().location
        let text = string
        let utf16 = text.utf16
        guard offset > 0, offset <= utf16.count else { return "" }
        var start = offset
        while start > 0 {
            let idx = utf16.index(utf16.startIndex, offsetBy: start - 1)
            let char = utf16[idx]
            // word character: alphanumeric or _
            if char == UInt16(0x5F) /* _ */ || (char >= 0x30 && char <= 0x39)
                || (char >= 0x41 && char <= 0x5A) || (char >= 0x61 && char <= 0x7A)
                || char > 0x7F {
                start -= 1
            } else {
                break
            }
            if offset - start > maxLength { break }
        }
        let startIdx = utf16.index(utf16.startIndex, offsetBy: start)
        let endIdx = utf16.index(utf16.startIndex, offsetBy: offset)
        return String(utf16[startIdx..<endIdx]) ?? ""
    }

    /// 上一次键入的字符（用于 trigger character 检测）
    var lastTypedCharacter: String? {
        // 通过 selectedRange 和前一字符推断
        let offset = selectedRange().location
        guard offset > 0 else { return nil }
        let utf16 = string.utf16
        let idx = utf16.index(utf16.startIndex, offsetBy: offset - 1)
        return String(utf16[idx])
    }

    /// 当前光标在 textView 坐标系里的矩形（用于面板定位）
    var cursorRect: NSRect {
        let offset = selectedRange().location
        guard let manager = layoutManager,
              let container = textContainer else { return .zero }
        let glyphIndex = manager.glyphIndexForCharacter(at: offset)
        var partial = CGFloat(0)
        let lineFragRect = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: false)
        partial = manager.location(forGlyphAt: glyphIndex).x
        return NSRect(
            x: lineFragRect.minX + partial + textContainerOrigin.x,
            y: lineFragRect.minY + textContainerOrigin.y,
            width: 2,
            height: lineFragRect.height
        )
    }
}
```

### Step 8: Xcode Cmd+B，0 errors

### Step 9: 手工冒烟测试

1. 打开一个有 LSP 的文件（Python / Swift）
2. 输入 `import`，停顿 200ms，确认补全面板出现
3. ⬇选到 `importlib`，Tab 接受，确认文本正确插入
4. 输入 `.`，确认 trigger character 立即弹出面板
5. 输入时快速打字（测试代际取消），确认不会出现旧结果
6. 输入中文 IME（切到输入法），确认面板不弹出
7. Esc 关闭面板

### Step 10: Commit

```
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "feat(F19): integrate completion trigger and panel into TextViewCoordinator"
```

---

## Task 8: CodeEditorView — 透传 completionEnabled 参数

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorView.swift`

### Step 1: 新增参数

```swift
// CodeEditorView.swift 参数列表中新增：
var isCompletionEnabled: Bool = false
```

并透传到 `CodeEditorTextView`：

```swift
// CodeEditorTextView 的 init 参数中新增：
var isCompletionEnabled: Bool = false
```

在 `makeNSView` 后，根据 `isCompletionEnabled` 决定是否 `installCompletion(for:coordinator:)`:

```swift
if parent.isCompletionEnabled {
    context.coordinator.installCompletion(
        for: textView,
        coordinator: parent.lspCoordinator  // 由外部注入
    )
}
```

> **说明：** `lspCoordinator` 由 `FileEditorView` 或上层 View 通过 environment 或参数传入，遵循 F19 约束第 5 条（Coordinator 隔离）。首轮可以先让 `CodeEditorTextView` 直接持有 `var lspCoordinator: CodeEditorLSPCoordinator?`，由 Coordinator 在 `updateNSView` 时注入。

### Step 2: Xcode Cmd+B，0 errors

### Step 3: Commit

```
git add agentGui/Views/CodeEditor/CodeEditorView.swift \
        agentGui/Views/CodeEditor/CodeEditorTextView.swift
git commit -m "feat(F19): wire completionEnabled parameter through view hierarchy"
```

---

## Task 9: 补充触发测试 — 代际取消场景

**Files:**
- Modify: `agentGuiTests/CodeEditorCompletionTriggerTests.swift`

### Step 1: 新增测试

```swift
// 在 CodeEditorCompletionTriggerTests 中新增：

@Test func rapidTypingCancelsOldSession_onlyLatestResultApplied() async {
    // 模拟：第 1 次 fetch 慢（200ms），第 2 次触发后第 1 次结果不应污染会话
    var callCount = 0
    var sessionUpdates: [CodeEditorCompletionSession?] = []
    let trigger = CodeEditorCompletionTrigger()
    trigger.onSessionChange = { sessionUpdates.append($0) }

    // 注入慢 + 快两次 fetch
    trigger.requestCompletion = { ctx, callback in
        callCount += 1
        let current = callCount
        Task {
            if current == 1 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms delay
                // 第一次请求被取消后返回 nil
                callback(nil)
            } else {
                callback([CodeEditorCompletionItem(label: "secondResult")])
            }
        }
    }
    trigger.cancelRequest = {}

    // 第一次触发（trigger character，立即）
    trigger.handleTyping(
        char: ".",
        cursorOffset: 5,
        prefixWord: "",
        triggerCharacters: ["."]
    )
    // 紧接着第二次触发（用户继续输入）
    trigger.handleTyping(
        char: "s",
        cursorOffset: 6,
        prefixWord: "s",
        triggerCharacters: ["."]
    )

    // 等待第二次 fetch 回来
    try? await Task.sleep(nanoseconds: 50_000_000)

    // 最终会话只包含 secondResult，不包含第一次结果
    let finalSession = trigger.currentSession
    #expect(finalSession?.items.first?.label == "secondResult")
}
```

### Step 2: 运行所有补全测试

```
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-f19-t3 \
  -only-testing:agentGuiTests/CodeEditorCompletionTriggerTests \
  -only-testing:agentGuiTests/CodeEditorCompletionInsertionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

期望：`** TEST SUCCEEDED **`

### Step 3: Final commit

```
git add agentGuiTests/CodeEditorCompletionTriggerTests.swift
git commit -m "feat(F19): add generation-cancel integration test, complete feature"
```

---

## 快速验收检查表

| 场景 | 预期 |
|------|------|
| 输入普通字符停顿 150ms | 面板出现，显示 LSP 返回项 |
| 连续快速输入 | 只有最后一次请求结果出现（代际取消验证） |
| 输入 trigger character (`."`, `":"`) | 立即弹出，不等 150ms |
| 继续输入追加字符 | 客户端前缀过滤，不重发 LSP（无网络延迟感） |
| ⬇⬆ 选择 | 面板高亮项移动 |
| Tab / Enter 接受 | 文本正确插入，光标移到 $0 位置（snippet）或末尾 |
| Esc | 面板关闭，不插入 |
| 光标移出当前词 | 面板关闭 |
| 中文 IME 输入中 | 面板不弹出 |
| LSP 服务端不支持 completion | 面板不弹出（`supportsCompletion == false`） |

---

## 跨 Feature 约束自查

- **IME 安全 ✓**：`hasMarkedText()` 检查 + `isInIMEComposition` flag，均在触发路径首位
- **代际取消 ✓**：`completionGeneration` 整型计数，callback 中比较 generation
- **Viewport-First ✓**：补全只针对当前光标位置，不预取视口外内容
- **Coordinator 隔离 ✓**：`CodeEditorCompletionTrigger.requestCompletion` 是注入闭包，不直接依赖上层 service
- **NSTextStorage 修改安全 ✓**：通过 `shouldChangeText + replaceCharacters + didChangeText` 保持 undo 栈完整
- **测试先行 ✓**：触发状态机 + 插入逻辑均有单元测试覆盖

---

*参考：VS Code suggestModel.ts / suggestController.ts / suggestWidget.ts (2026-04)*
