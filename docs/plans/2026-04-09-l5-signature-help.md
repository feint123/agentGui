# L5: 签名帮助（Signature Help）实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在代码编辑器函数调用括号内实时显示参数签名浮层，高亮当前参数，支持多重载切换，对标 VSCode `parameterHints` 贡献点行为。

**Architecture:** 参照 VSCode `ParameterHintsModel` 三态机（Default / Pending / Active）和 `ParameterHintsWidget` 浮层模式，在 agentGui 中实现类似的分层——`CodeEditorSignatureHelpTrigger`（状态机）负责触发去抖、代际仲裁；`CodeEditorSignatureHelpPanel`（NSPanel 浮层）负责渲染签名与高亮参数；`CodeEditorLSPCoordinator` 作为桥接层向 LSP 服务器发请求并把结果分发到 Trigger。

**Tech Stack:** Swift 6.0 + AppKit (NSPanel) + LSP 3.17 `textDocument/signatureHelp`

**参考源码：**
- `vscode/src/vs/editor/contrib/parameterHints/browser/parameterHintsModel.ts` — 触发状态机、trigger/retrigger char 集合、节流去抖逻辑
- `vscode/src/vs/editor/contrib/parameterHints/browser/parameterHintsWidget.ts` — 签名渲染（active param attribute string）、多重载 UI、positioning preference

---

## 前置条件

- L-1（Capability 协商）已完成：`LSPServerCapabilityHints` 已包含 `supportsSignatureHelp`、`signatureHelpTriggerCharacters`、`signatureHelpRetriggerCharacters` 字段并从服务器响应解析。
- `LSPClient.completion` 方法作为请求模板可参考。
- `CodeEditorCompletionPanel` / `CodeEditorCompletionTrigger` 作为 UI 和状态机模板可参考。

---

## Task 1：LSP 数据模型

**目标：** 定义 `LSPSignatureHelp`、`LSPSignatureInformation`、`LSPParameterInformation`、`SignatureHelpTriggerContext` 结构体，用于在 `LSPClient` 和 `CodeEditorLSPCoordinator` 之间传递数据。

**Files:**
- Create: `agentGui/Models/LSPSignatureHelpModels.swift`
- Test: `agentGuiTests/LSPSignatureHelpModelsTests.swift`

---

### Step 1: 写失败测试

```swift
// agentGuiTests/LSPSignatureHelpModelsTests.swift
import Testing
@testable import agentGui

@Suite("LSPSignatureHelpModels")
struct LSPSignatureHelpModelsTests {

    // MARK: - LSPParameterLabelOffset

    @Test func parameterLabelOffset_arrayForm_returnsCorrectRange() {
        let param = LSPParameterInformation(
            label: .range(5, 10),
            documentation: nil
        )
        guard case .range(let start, let end) = param.label else {
            Issue.record("expected .range")
            return
        }
        #expect(start == 5)
        #expect(end == 10)
    }

    @Test func parameterLabelOffset_stringForm_returnsString() {
        let param = LSPParameterInformation(
            label: .text("value"),
            documentation: nil
        )
        guard case .text(let s) = param.label else {
            Issue.record("expected .text")
            return
        }
        #expect(s == "value")
    }

    // MARK: - LSPSignatureInformation

    @Test func signatureInformation_decodeFromDict_fieldsCorrect() throws {
        let raw: [String: Any] = [
            "label": "print(_ value: Any)",
            "documentation": ["kind": "markdown", "value": "Prints to stdout."],
            "parameters": [
                ["label": "value", "documentation": "The item to print."]
            ],
            "activeParameter": 0
        ]
        let sig = try LSPSignatureInformation(raw: raw)
        #expect(sig.label == "print(_ value: Any)")
        #expect(sig.parameters.count == 1)
        #expect(sig.activeParameter == 0)
    }

    // MARK: - LSPSignatureHelp

    @Test func signatureHelp_emptySignatures_isInvalid() {
        let help = LSPSignatureHelp(signatures: [], activeSignature: 0, activeParameter: 0)
        #expect(!help.isValid)
    }

    @Test func signatureHelp_nonEmptySignatures_isValid() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int)",
            documentation: nil,
            parameters: [],
            activeParameter: nil
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        #expect(help.isValid)
    }

    @Test func signatureHelp_activeParameterResolution_usesSignatureLevelFirst() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int, b: String)",
            documentation: nil,
            parameters: [
                LSPParameterInformation(label: .text("a: Int"), documentation: nil),
                LSPParameterInformation(label: .text("b: String"), documentation: nil)
            ],
            activeParameter: 1   // signature-level override
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        // signature-level activeParameter wins over top-level
        #expect(help.resolvedActiveParameter(for: 0) == 1)
    }

    @Test func signatureHelp_activeParameterResolution_fallsBackToTopLevel() {
        let sig = LSPSignatureInformation(
            label: "foo(a: Int, b: String)",
            documentation: nil,
            parameters: [
                LSPParameterInformation(label: .text("a: Int"), documentation: nil),
                LSPParameterInformation(label: .text("b: String"), documentation: nil)
            ],
            activeParameter: nil   // no signature-level value
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 1)
        #expect(help.resolvedActiveParameter(for: 0) == 1)
    }
}
```

**Step 2: 运行验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task1 \
  -only-testing:agentGuiTests/LSPSignatureHelpModelsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败，`LSPSignatureHelpModels.swift` 不存在。

---

### Step 3: 实现模型文件

```swift
// agentGui/Models/LSPSignatureHelpModels.swift

import Foundation

// MARK: - Parameter Label

/// 参数标签：来自 LSP spec，可以是字符串或 [start, end] 偏移区间。
enum LSPParameterLabel: Sendable, Equatable {
    case text(String)
    case range(Int, Int)   // 半开区间：[start, end) in the signature label bytes
}

// MARK: - Parameter Information

struct LSPParameterInformation: Sendable {
    let label: LSPParameterLabel
    let documentation: String?

    init(label: LSPParameterLabel, documentation: String?) {
        self.label = label
        self.documentation = documentation
    }

    /// 从 LSP raw dict 解析
    init(raw: [String: Any]) throws {
        let labelRaw = raw["label"]
        if let s = labelRaw as? String {
            self.label = .text(s)
        } else if let arr = labelRaw as? [Int], arr.count == 2 {
            self.label = .range(arr[0], arr[1])
        } else {
            throw LSPSignatureHelpParseError.missingField("parameters[].label")
        }

        if let docStr = raw["documentation"] as? String {
            self.documentation = docStr
        } else if let docObj = raw["documentation"] as? [String: Any],
                  let value = docObj["value"] as? String {
            self.documentation = value
        } else {
            self.documentation = nil
        }
    }
}

// MARK: - Signature Information

struct LSPSignatureInformation: Sendable {
    let label: String
    let documentation: String?
    let parameters: [LSPParameterInformation]
    /// signature-level activeParameter（LSP 3.16+），优先于顶层字段
    let activeParameter: Int?

    init(label: String, documentation: String?, parameters: [LSPParameterInformation], activeParameter: Int?) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }

    init(raw: [String: Any]) throws {
        guard let label = raw["label"] as? String else {
            throw LSPSignatureHelpParseError.missingField("signatures[].label")
        }
        self.label = label

        if let docStr = raw["documentation"] as? String {
            self.documentation = docStr
        } else if let docObj = raw["documentation"] as? [String: Any],
                  let value = docObj["value"] as? String {
            self.documentation = value
        } else {
            self.documentation = nil
        }

        let rawParams = (raw["parameters"] as? [[String: Any]]) ?? []
        self.parameters = try rawParams.map { try LSPParameterInformation(raw: $0) }
        self.activeParameter = raw["activeParameter"] as? Int
    }
}

// MARK: - Signature Help (top-level result)

struct LSPSignatureHelp: Sendable {
    let signatures: [LSPSignatureInformation]
    let activeSignature: Int
    let activeParameter: Int    // 顶层 fallback

    var isValid: Bool { !signatures.isEmpty }

    /// 解析活跃参数索引：per-signature 优先（LSP 3.16 spec §3.16.0）
    func resolvedActiveParameter(for signatureIndex: Int) -> Int {
        guard signatureIndex < signatures.count else { return activeParameter }
        return signatures[signatureIndex].activeParameter ?? activeParameter
    }

    /// 当前活跃签名（安全边界检查）
    var activeSignatureInfo: LSPSignatureInformation? {
        guard activeSignature < signatures.count else { return nil }
        return signatures[activeSignature]
    }
}

// MARK: - Trigger Context

enum LSPSignatureHelpTriggerKind: Int, Sendable {
    case invoked = 1
    case triggerCharacter = 2
    case contentChange = 3
}

struct SignatureHelpTriggerContext: Sendable {
    let triggerKind: LSPSignatureHelpTriggerKind
    let triggerCharacter: String?
    let isRetrigger: Bool
    /// 前一次的活跃结果，用于 retrigger（VSCode 会传回服务器）
    let activeSignatureHelp: LSPSignatureHelp?
}

// MARK: - Errors

enum LSPSignatureHelpParseError: Error {
    case missingField(String)
}
```

**Step 4: 运行验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task1 \
  -only-testing:agentGuiTests/LSPSignatureHelpModelsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`Test Suite 'LSPSignatureHelpModelsTests' passed`，7 个测试全部绿色。

**Step 5: Commit**

```bash
git add agentGui/Models/LSPSignatureHelpModels.swift \
        agentGuiTests/LSPSignatureHelpModelsTests.swift
git commit -m "feat(l5): add LSP signature help data models"
```

---

## Task 2：LSPClient – signatureHelp 请求方法

**目标：** 在 `LSPClient` 中增加 `signatureHelp(uri:line:character:context:)` 方法，发送 `textDocument/signatureHelp` 请求，并把 raw JSON 解析为 `LSPSignatureHelp?`。

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`
- Test: `agentGuiTests/LSPSignatureHelpModelsTests.swift`（追加到 Task 1 的测试文件）

---

### Step 1: 写失败测试

在 `LSPSignatureHelpModelsTests.swift` 追加一个 section，用 mock transport 验证请求格式和结果解析：

```swift
// 追加到 agentGuiTests/LSPSignatureHelpModelsTests.swift

@Suite("LSPClient signatureHelp parsing")
struct LSPClientSignatureHelpParsingTests {

    // 测试 raw JSON → LSPSignatureHelp 解析正确性（不需要真实服务器）
    @Test func parse_pylspStyleResponse_returnsValidHelp() throws {
        let raw: [String: Any] = [
            "signatures": [
                [
                    "label": "print(*objects, sep=' ', end='\\n', file=None, flush=False)",
                    "parameters": [
                        ["label": "objects"],
                        ["label": "sep"],
                        ["label": "end"],
                        ["label": "file"],
                        ["label": "flush"]
                    ]
                ]
            ],
            "activeSignature": 0,
            "activeParameter": 1
        ]
        let help = try LSPClientSignatureHelpParser.parse(raw: raw)
        #expect(help?.isValid == true)
        #expect(help?.signatures[0].parameters.count == 5)
        #expect(help?.resolvedActiveParameter(for: 0) == 1)
    }

    @Test func parse_nullResult_returnsNil() throws {
        let help = try LSPClientSignatureHelpParser.parse(raw: nil)
        #expect(help == nil)
    }

    @Test func parse_emptySignatures_returnsNil() throws {
        let raw: [String: Any] = ["signatures": [], "activeSignature": 0, "activeParameter": 0]
        let help = try LSPClientSignatureHelpParser.parse(raw: raw)
        #expect(help == nil)   // isValid == false → 归一为 nil
    }
}
```

**Step 2: 运行验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task2 \
  -only-testing:agentGuiTests/LSPClientSignatureHelpParsingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败，`LSPClientSignatureHelpParser` 不存在。

---

### Step 3: 实现 Parser + LSPClient 方法

**Step 3a: 在 `LSPSignatureHelpModels.swift` 底部追加 parser 命名空间**

```swift
// 追加到 agentGui/Models/LSPSignatureHelpModels.swift

// MARK: - Parser

enum LSPClientSignatureHelpParser {
    static func parse(raw: Any?) throws -> LSPSignatureHelp? {
        guard let dict = raw as? [String: Any] else { return nil }

        let rawSigs = (dict["signatures"] as? [[String: Any]]) ?? []
        if rawSigs.isEmpty { return nil }

        let signatures = try rawSigs.map { try LSPSignatureInformation(raw: $0) }
        let activeSignature = (dict["activeSignature"] as? Int) ?? 0
        let activeParameter = (dict["activeParameter"] as? Int) ?? 0

        let help = LSPSignatureHelp(
            signatures: signatures,
            activeSignature: max(0, min(activeSignature, signatures.count - 1)),
            activeParameter: activeParameter
        )
        return help.isValid ? help : nil
    }
}
```

**Step 3b: 在 `LSPClient.swift` 中添加 `signatureHelp` 方法**

在 hover 方法附近追加（`// MARK: - Semantic queries` section）：

```swift
// agentGui/Services/LSP/LSPClient.swift
// 在现有 hover 方法之后插入：

func signatureHelp(
    uri: String,
    line: Int,
    character: Int,
    context: SignatureHelpTriggerContext
) async -> LSPSignatureHelp? {
    var contextDict: [String: Any] = [
        "triggerKind": context.triggerKind.rawValue,
        "isRetrigger": context.isRetrigger
    ]
    if let ch = context.triggerCharacter {
        contextDict["triggerCharacter"] = ch
    }
    // activeSignatureHelp：retrigger 时把前一次结果传回（LSP spec §3.16.0）
    if let prev = context.activeSignatureHelp, context.isRetrigger {
        contextDict["activeSignatureHelp"] = [
            "signatures": prev.signatures.map { sig -> [String: Any] in
                var d: [String: Any] = ["label": sig.label]
                if let p = sig.activeParameter { d["activeParameter"] = p }
                return d
            },
            "activeSignature": prev.activeSignature,
            "activeParameter": prev.activeParameter
        ]
    }

    let params: [String: Any] = [
        "textDocument": ["uri": uri],
        "position": ["line": line, "character": character],
        "context": contextDict
    ]

    guard let result = try? await transport.sendRequest(
        method: "textDocument/signatureHelp",
        params: params
    ) else { return nil }

    return try? LSPClientSignatureHelpParser.parse(raw: result)
}
```

**Step 4: 运行验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task2 \
  -only-testing:agentGuiTests/LSPClientSignatureHelpParsingTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：3 个测试全绿。

**Step 5: Commit**

```bash
git add agentGui/Models/LSPSignatureHelpModels.swift \
        agentGui/Services/LSP/LSPClient.swift \
        agentGuiTests/LSPSignatureHelpModelsTests.swift
git commit -m "feat(l5): add LSPClient.signatureHelp method and parser"
```

---

## Task 3：CodeEditorSignatureHelpTrigger — 触发状态机

**目标：** 实现签名帮助的触发状态机，对标 VSCode `ParameterHintsModel`：
- **三态：** `.default` / `.pending(generation, previousHelp)` / `.active(help)`
- **trigger chars**（如 `(`）→ 立即触发
- **retrigger chars**（如 `,`）→ 仅在 active/pending 时触发
- **内容变更**（ContentChange）→ 仅在 active/pending 时 retrigger
- **鼠标光标移动 / Esc / blur** → cancel 转回 `.default`
- **代际仲裁：** 每次触发分配递增 `generation`，响应回调时检查匹配

**Files:**
- Create: `agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift`
- Test: `agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift`

---

### Step 1: 写失败测试

```swift
// agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift
import Testing
@testable import agentGui

@Suite("CodeEditorSignatureHelpTrigger")
@MainActor
struct CodeEditorSignatureHelpTriggerTests {

    // MARK: - trigger char 立即触发

    @Test func triggerChar_whenDefault_firesRequest() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            callback(nil)
        }

        trigger.handleTyping(
            char: "(",
            cursorOffset: 10,
            triggerCharacters: ["(", ","],
            retriggerCharacters: [",", ")"]
        )
        // 触发去抖窗口后等待
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 1)
    }

    // MARK: - retrigger char 仅在 active 时触发

    @Test func retriggerChar_whenDefault_doesNotFire() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            callback(nil)
        }
        // "," 是 retrigger char，但当前是 default 状态
        trigger.handleTyping(
            char: ",",
            cursorOffset: 5,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 0)
    }

    @Test func retriggerChar_whenActive_fires() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        // 第一次用 trigger char 激活
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            let sig = LSPSignatureInformation(
                label: "foo(a, b)", documentation: nil,
                parameters: [
                    LSPParameterInformation(label: .text("a"), documentation: nil),
                    LSPParameterInformation(label: .text("b"), documentation: nil)
                ],
                activeParameter: nil
            )
            callback(LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }
        trigger.handleTyping(
            char: "(",
            cursorOffset: 5,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 1)   // active 状态

        // 现在输入 ","（retrigger char）
        trigger.handleTyping(
            char: ",",
            cursorOffset: 6,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 2)
    }

    // MARK: - cancel

    @Test func cancel_whenActive_transitionsToDefault_firesNilSession() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var sessions: [LSPSignatureHelp?] = []
        trigger.onSessionChange = { sessions.append($0) }

        trigger.requestSignatureHelp = { _, callback in
            let sig = LSPSignatureInformation(
                label: "foo(a)", documentation: nil,
                parameters: [LSPParameterInformation(label: .text("a"), documentation: nil)],
                activeParameter: nil
            )
            callback(LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }

        trigger.handleTyping(
            char: "(",
            cursorOffset: 3,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(sessions.last??.isValid == true)

        trigger.cancel()
        #expect(sessions.last == Optional<LSPSignatureHelp>.none)
    }

    // MARK: - 代际仲裁：旧响应不覆盖新状态

    @Test func staleResponse_doesNotOverwriteNewerRequest() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var sessionUpdates: [LSPSignatureHelp??] = []
        trigger.onSessionChange = { sessionUpdates.append($0) }

        var callbacks: [((LSPSignatureHelp?) -> Void)] = []
        trigger.requestSignatureHelp = { _, cb in callbacks.append(cb) }

        // 第一个请求（generation 1）
        trigger.handleTyping(char: "(", cursorOffset: 3,
                             triggerCharacters: ["("], retriggerCharacters: [","])
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 第二个请求（generation 2）覆盖
        trigger.handleTyping(char: "(", cursorOffset: 4,
                             triggerCharacters: ["("], retriggerCharacters: [","])
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 先回调 generation 1（stale）
        if callbacks.count >= 1 {
            let sig = LSPSignatureInformation(
                label: "stale()", documentation: nil, parameters: [], activeParameter: nil)
            callbacks[0](LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }
        // 再回调 generation 2（fresh）
        if callbacks.count >= 2 {
            let sig = LSPSignatureInformation(
                label: "fresh()", documentation: nil, parameters: [], activeParameter: nil)
            callbacks[1](LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }

        // session 应该是 fresh，不是 stale
        let finalHelp = sessionUpdates.last.flatMap { $0 }
        #expect(finalHelp?.signatures[0].label == "fresh()")
    }

    // MARK: - overload 切换

    @Test func next_cyclesThroughSignatures() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var lastSession: LSPSignatureHelp?
        trigger.onSessionChange = { lastSession = $0 }

        trigger.requestSignatureHelp = { _, cb in
            let sigs = [
                LSPSignatureInformation(label: "foo(a)", documentation: nil,
                                        parameters: [], activeParameter: nil),
                LSPSignatureInformation(label: "foo(a, b)", documentation: nil,
                                        parameters: [], activeParameter: nil)
            ]
            cb(LSPSignatureHelp(signatures: sigs, activeSignature: 0, activeParameter: 0))
        }

        trigger.handleTyping(char: "(", cursorOffset: 3,
                             triggerCharacters: ["("], retriggerCharacters: [","])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(lastSession?.activeSignature == 0)

        trigger.next()
        #expect(lastSession?.activeSignature == 1)

        trigger.next()   // 到达末端，循环回 0
        #expect(lastSession?.activeSignature == 0)
    }
}
```

**Step 2: 运行验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task3 \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpTriggerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败，`CodeEditorSignatureHelpTrigger` 不存在。

---

### Step 3: 实现状态机

```swift
// agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift

import Foundation

// MARK: - State

private enum SignatureHelpState {
    case `default`
    case pending(generation: Int, previousHelp: LSPSignatureHelp?)
    case active(help: LSPSignatureHelp)

    var isTriggered: Bool {
        switch self {
        case .default: return false
        case .pending, .active: return true
        }
    }

    var activeHelp: LSPSignatureHelp? {
        if case .active(let h) = self { return h }
        if case .pending(_, let prev) = self { return prev }
        return nil
    }
}

// MARK: - CodeEditorSignatureHelpTrigger

/// 签名帮助触发状态机（对标 VSCode ParameterHintsModel）
/// - 仅 trigger char 时发新请求
/// - retrigger char / ContentChange 仅在 active/pending 时发 retrigger
/// - cancel 后转回 .default 并通知 onSessionChange(nil)
@MainActor
final class CodeEditorSignatureHelpTrigger {

    // MARK: - Callbacks (injected by CodeEditorTextView.Coordinator)

    /// 派发 LSP 请求，回调在 @MainActor 执行
    var requestSignatureHelp: ((SignatureHelpTriggerContext, @MainActor @escaping (LSPSignatureHelp?) -> Void) -> Void)?

    /// 状态更新时回调（nil = 隐藏浮层）
    var onSessionChange: ((LSPSignatureHelp?) -> Void)?

    // MARK: - Private state

    private var state: SignatureHelpState = .default
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    // MARK: - Trigger / Retrigger

    /// 用户键入字符后调用
    func handleTyping(
        char: String,
        cursorOffset: Int,
        triggerCharacters: [String],
        retriggerCharacters: [String]
    ) {
        let isTrigger = triggerCharacters.contains(char)
        let isRetrigger = state.isTriggered && retriggerCharacters.contains(char)

        if isTrigger {
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char,
                    isRetrigger: state.isTriggered,
                    activeSignatureHelp: state.activeHelp
                )
            )
        } else if isRetrigger {
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char,
                    isRetrigger: true,
                    activeSignatureHelp: state.activeHelp
                )
            )
        } else if state.isTriggered {
            // 普通字符 + active → contentChange retrigger
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .contentChange,
                    triggerCharacter: nil,
                    isRetrigger: true,
                    activeSignatureHelp: state.activeHelp
                )
            )
        }
    }

    /// 手动触发（Ctrl+Cmd+Space 快捷键）
    func invoke(cursorOffset: Int) {
        scheduleTrigger(
            context: SignatureHelpTriggerContext(
                triggerKind: .invoked,
                triggerCharacter: nil,
                isRetrigger: state.isTriggered,
                activeSignatureHelp: state.activeHelp
            ),
            delay: 0
        )
    }

    // MARK: - Cancel

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        if case .default = state { return }
        state = .default
        onSessionChange?(nil)
    }

    // MARK: - Overload Navigation

    func next() {
        guard case .active(let help) = state, help.signatures.count > 1 else { return }
        let nextIdx = (help.activeSignature + 1) % help.signatures.count
        let updated = LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: nextIdx,
            activeParameter: help.activeParameter
        )
        state = .active(help: updated)
        onSessionChange?(updated)
    }

    func previous() {
        guard case .active(let help) = state, help.signatures.count > 1 else { return }
        let count = help.signatures.count
        let prevIdx = (help.activeSignature + count - 1) % count
        let updated = LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: prevIdx,
            activeParameter: help.activeParameter
        )
        state = .active(help: updated)
        onSessionChange?(updated)
    }

    // MARK: - Private

    private func scheduleTrigger(
        context: SignatureHelpTriggerContext,
        delay: UInt64 = 120_000_000   // 120ms，对标 VSCode DEFAULT_DELAY
    ) {
        debounceTask?.cancel()
        generation &+= 1
        let currentGeneration = generation

        if delay == 0 {
            doTrigger(context: context, generation: currentGeneration)
            return
        }

        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self.doTrigger(context: context, generation: currentGeneration)
        }
    }

    private func doTrigger(context: SignatureHelpTriggerContext, generation: Int) {
        let previousHelp = state.activeHelp
        state = .pending(generation: generation, previousHelp: previousHelp)

        requestSignatureHelp?(context) { [weak self] result in
            guard let self else { return }
            // 代际仲裁：仅当响应与当前 pending generation 匹配时才更新
            guard case .pending(let pendingGen, _) = self.state,
                  pendingGen == generation else { return }

            if let help = result, help.isValid {
                self.state = .active(help: help)
                self.onSessionChange?(help)
            } else {
                self.cancel()
            }
        }
    }
}
```

**Step 4: 运行验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task3 \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpTriggerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：7 个测试全绿。

**Step 5: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift \
        agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift
git commit -m "feat(l5): add CodeEditorSignatureHelpTrigger state machine"
```

---

## Task 4：CodeEditorLSPCoordinator — 集成触发器

**目标：** 在 `CodeEditorLSPCoordinator` 中添加 `requestSignatureHelp` 方法，供 `CodeEditorSignatureHelpTrigger` 回调使用；协调器从 `LSPClient.signatureHelp` 获取结果后通知调用方。

**Files:**
- Modify: `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift`
- Test: `agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift`（追加集成测试）

---

### Step 1: 写失败测试

在 `CodeEditorSignatureHelpTriggerTests.swift` 底部追加一个集成场景（用 `MockLSPClient` 验证 coordinator 调用链）：

```swift
// 追加到 agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift
// 注：MockLSPClient/MockLSPSessionManager 是现有测试 mock——复用已有的 mock 模式

@Suite("CodeEditorLSPCoordinator signatureHelp integration")
@MainActor
struct CoordinatorSignatureHelpIntegrationTests {

    @Test func requestSignatureHelp_dispatchesToLSPClient() async throws {
        // 假设已有 MockLSPManagerForSignatureHelp 参照 MockLSPSessionManager 模式创建
        // 此处验证 coordinator 把 trigger context 正确路由到 client 方法
        let mockManager = MockLSPSessionManagerForSignatureHelp()
        let coordinator = CodeEditorLSPCoordinator(
            uri: "file:///test.py",
            languageID: "python",
            manager: mockManager
        )

        let context = SignatureHelpTriggerContext(
            triggerKind: .triggerCharacter,
            triggerCharacter: "(",
            isRetrigger: false,
            activeSignatureHelp: nil
        )

        var received: LSPSignatureHelp?
        coordinator.requestSignatureHelp(context: context, line: 5, character: 10) { result in
            received = result
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(mockManager.signatureHelpCallCount == 1)
        #expect(received?.isValid == true)
    }
}
```

---

### Step 2: 实现 coordinator 方法

在 `CodeEditorLSPCoordinator.swift` 中，参照 `requestCompletion` 模式追加：

```swift
// agentGui/Services/Editor/CodeEditorLSPCoordinator.swift
// 在 requestCompletion 方法之后插入：

// MARK: - Signature Help

private var signatureHelpGeneration: Int = 0
private var pendingSignatureHelpTask: Task<Void, Never>?

func requestSignatureHelp(
    context: SignatureHelpTriggerContext,
    line: Int,
    character: Int,
    onResult: @MainActor @escaping (LSPSignatureHelp?) -> Void
) {
    signatureHelpGeneration &+= 1
    let generation = signatureHelpGeneration
    pendingSignatureHelpTask?.cancel()

    pendingSignatureHelpTask = Task { [weak self] in
        guard let self, let session = await self.manager.session(for: self.uri) else {
            await MainActor.run { onResult(nil) }
            return
        }
        let result = await session.client.signatureHelp(
            uri: self.uri,
            line: line,
            character: character,
            context: context
        )
        await MainActor.run { [weak self] in
            guard let self, self.signatureHelpGeneration == generation else { return }
            onResult(result)
        }
    }
}

func cancelSignatureHelp() {
    pendingSignatureHelpTask?.cancel()
    pendingSignatureHelpTask = nil
}
```

**Step 3: 运行验证**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task4 \
  -only-testing:agentGuiTests/CoordinatorSignatureHelpIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：测试通过。

**Step 4: Commit**

```bash
git add agentGui/Services/Editor/CodeEditorLSPCoordinator.swift \
        agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift
git commit -m "feat(l5): add signatureHelp dispatch in CodeEditorLSPCoordinator"
```

---

## Task 5：CodeEditorSignatureHelpPanel — 浮层 UI

**目标：** 实现 `CodeEditorSignatureHelpPanel`（NSPanel 浮层），显示：
1. 签名标签，用 **粗体** 高亮当前活跃参数
2. 参数文档（可选）
3. 多重载时显示 "1/3" 计数器 + ↑↓ 按钮
4. 光标下方定位，空间不足时翻转到上方

参照 VSCode `ParameterHintsWidget` 的渲染逻辑（`renderParameters`、`getParameterLabelOffsets`）和 agentGui 现有 `CodeEditorCompletionPanel` 的 NSPanel + NSView 模式。

**Files:**
- Create: `agentGui/Views/CodeEditor/CodeEditorSignatureHelpPanel.swift`
- Test: `agentGuiTests/CodeEditorSignatureHelpPanelTests.swift`

---

### Step 1: 写失败测试

```swift
// agentGuiTests/CodeEditorSignatureHelpPanelTests.swift
import Testing
import AppKit
@testable import agentGui

@Suite("CodeEditorSignatureHelpPanel")
@MainActor
struct CodeEditorSignatureHelpPanelTests {

    @Test func update_singleSignature_panelNotVisible_thenShow_becomesVisible() {
        let panel = CodeEditorSignatureHelpPanel()
        let sig = LSPSignatureInformation(
            label: "print(value: Any)",
            documentation: "Prints value to stdout.",
            parameters: [LSPParameterInformation(label: .text("value: Any"), documentation: nil)],
            activeParameter: nil
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)

        panel.update(help: help)
        #expect(!panel.isVisible)   // update 不自动显示
    }

    @Test func hide_afterShow_panelBecomesInvisible() {
        let panel = CodeEditorSignatureHelpPanel()
        let sig = LSPSignatureInformation(
            label: "foo(a: Int)",
            documentation: nil,
            parameters: [LSPParameterInformation(label: .text("a: Int"), documentation: nil)],
            activeParameter: nil
        )
        panel.update(help: LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        // 创建一个 host window 用于测试
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.show(anchoredBelow: NSRect(x: 100, y: 300, width: 10, height: 16), in: window)
        panel.hide()
        #expect(!panel.isVisible)
    }

    @Test func attributedLabel_withArrayRangeParam_highlightsCorrectSubstring() {
        let panel = CodeEditorSignatureHelpPanel()
        // "print(*objects)" → parameter label は [6, 14]（bytes）
        let sig = LSPSignatureInformation(
            label: "print(*objects)",
            documentation: nil,
            parameters: [LSPParameterInformation(label: .range(6, 14), documentation: nil)],
            activeParameter: 0
        )
        let help = LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0)
        let attributed = panel.buildAttributedLabel(for: help)
        // 高亮范围应等于 [6,14) 的字符范围 "*objects"
        var foundBold = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let font = value as? NSFont, range.location == 6, range.length == 8 {
                foundBold = font.fontDescriptor.symbolicTraits.contains(.bold)
            }
        }
        #expect(foundBold)
    }

    @Test func overloadCounter_multipleSignatures_showsCorrectFraction() {
        let panel = CodeEditorSignatureHelpPanel()
        let sigs = [
            LSPSignatureInformation(label: "foo(a)", documentation: nil, parameters: [], activeParameter: nil),
            LSPSignatureInformation(label: "foo(a, b)", documentation: nil, parameters: [], activeParameter: nil),
            LSPSignatureInformation(label: "foo(a, b, c)", documentation: nil, parameters: [], activeParameter: nil),
        ]
        let help = LSPSignatureHelp(signatures: sigs, activeSignature: 1, activeParameter: 0)
        panel.update(help: help)
        #expect(panel.overloadCounterText == "2/3")
    }
}
```

**Step 2: 运行验证失败**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task5 \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpPanelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译失败。

---

### Step 3: 实现 Panel

```swift
// agentGui/Views/CodeEditor/CodeEditorSignatureHelpPanel.swift

import AppKit

// MARK: - CodeEditorSignatureHelpPanel

/// NSPanel 签名帮助浮层。
/// 布局（从上到下）：
///   [overloads label]  [↑] [↓]
///   [signature attributed label]
///   [documentation label（可选）]
@MainActor
final class CodeEditorSignatureHelpPanel: NSObject {

    static let panelWidth: CGFloat = 420
    static let minPanelHeight: CGFloat = 32
    static let maxPanelHeight: CGFloat = 180

    // MARK: - Public state

    private(set) var isVisible: Bool = false
    private(set) var overloadCounterText: String = ""

    // MARK: - Callbacks

    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    // MARK: - Windowing

    let panel: NSPanel
    private let contentView = NSView()
    private let signatureLabel = NSTextField(labelWithString: "")
    private let docsLabel = NSTextField(wrappingLabelWithString: "")
    private let overloadsLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: "↑", target: nil, action: nil)
    private let nextButton = NSButton(title: "↓", target: nil, action: nil)

    // MARK: - Init

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.minPanelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
        setupPanel()
    }

    private func setupPanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = container

        // overloads row
        overloadsLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        overloadsLabel.textColor = .secondaryLabelColor
        [prevButton, nextButton].forEach {
            $0.bezelStyle = .inline
            $0.isBordered = false
            $0.font = NSFont.systemFont(ofSize: 11)
            $0.target = self
        }
        prevButton.action = #selector(didClickPrevious)
        nextButton.action = #selector(didClickNext)

        signatureLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        signatureLabel.isEditable = false
        signatureLabel.isBordered = false
        signatureLabel.backgroundColor = .clear
        signatureLabel.lineBreakMode = .byTruncatingTail
        signatureLabel.maximumNumberOfLines = 2

        docsLabel.font = NSFont.systemFont(ofSize: 11)
        docsLabel.textColor = .secondaryLabelColor
        docsLabel.maximumNumberOfLines = 4

        [overloadsLabel, prevButton, nextButton, signatureLabel, docsLabel].forEach {
            ($0 as! NSView).translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0 as! NSView)
        }

        NSLayoutConstraint.activate([
            overloadsLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            overloadsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),

            prevButton.centerYAnchor.constraint(equalTo: overloadsLabel.centerYAnchor),
            prevButton.leadingAnchor.constraint(equalTo: overloadsLabel.trailingAnchor, constant: 4),

            nextButton.centerYAnchor.constraint(equalTo: overloadsLabel.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),

            signatureLabel.topAnchor.constraint(equalTo: overloadsLabel.bottomAnchor, constant: 4),
            signatureLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            signatureLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            docsLabel.topAnchor.constraint(equalTo: signatureLabel.bottomAnchor, constant: 4),
            docsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            docsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            docsLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - Public API

    func update(help: LSPSignatureHelp) {
        let multiple = help.signatures.count > 1
        overloadsLabel.isHidden = !multiple
        prevButton.isHidden = !multiple
        nextButton.isHidden = !multiple

        overloadsLabel.stringValue = multiple
            ? "\(help.activeSignature + 1)/\(help.signatures.count)"
            : ""
        overloadCounterText = overloadsLabel.stringValue

        let attributed = buildAttributedLabel(for: help)
        signatureLabel.attributedStringValue = attributed

        // docs
        let activeParam = help.resolvedActiveParameter(for: help.activeSignature)
        var docText = ""
        if let sig = help.activeSignatureInfo {
            if activeParam < sig.parameters.count,
               let paramDoc = sig.parameters[activeParam].documentation {
                docText = paramDoc
            } else if let sigDoc = sig.documentation {
                docText = sigDoc
            }
        }
        docsLabel.stringValue = docText
        docsLabel.isHidden = docText.isEmpty
    }

    func show(anchoredBelow cursorRect: NSRect, in window: NSWindow) {
        positionPanel(below: cursorRect, in: window)
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        isVisible = true
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Attributed Label Building

    /// 构建签名高亮 AttributedString（高亮当前活跃参数，对标 VSCode renderParameters）
    func buildAttributedLabel(for help: LSPSignatureHelp) -> NSAttributedString {
        guard let sig = help.activeSignatureInfo else {
            return NSAttributedString(string: "")
        }
        let label = sig.label
        let activeParam = help.resolvedActiveParameter(for: help.activeSignature)

        let attributed = NSMutableAttributedString(string: label)
        let fullRange = NSRange(location: 0, length: (label as NSString).length)

        // 默认字体
        let normalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        attributed.addAttribute(.font, value: normalFont, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // 高亮当前参数
        if activeParam < sig.parameters.count {
            let param = sig.parameters[activeParam]
            let highlightRange = parameterLabelRange(param: param, in: label)
            if let r = highlightRange {
                attributed.addAttribute(.font, value: boldFont, range: r)
                attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
            }
        }
        return attributed
    }

    // MARK: - Private

    private func parameterLabelRange(param: LSPParameterInformation, in label: String) -> NSRange? {
        let nsLabel = label as NSString
        switch param.label {
        case .range(let start, let end):
            // LSP 使用 UTF-16 偏移，需转换为 NSRange（NSString 也是 UTF-16）
            let length = end - start
            guard start >= 0, end <= nsLabel.length, length >= 0 else { return nil }
            return NSRange(location: start, length: length)
        case .text(let paramStr):
            let found = nsLabel.range(of: paramStr)
            return found.location == NSNotFound ? nil : found
        }
    }

    private func positionPanel(below cursorRect: NSRect, in window: NSWindow) {
        let screenRect = window.convertToScreen(cursorRect)
        let panelWidth = Self.panelWidth

        // 先测量内容高度
        panel.contentView?.layoutSubtreeIfNeeded()
        let idealHeight = min(
            max(panel.contentView?.fittingSize.height ?? Self.minPanelHeight, Self.minPanelHeight),
            Self.maxPanelHeight
        )

        var origin = NSPoint(
            x: screenRect.minX,
            y: screenRect.minY - idealHeight - 4
        )
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y < frame.minY {
                // 空间不足，改为显示在光标上方
                origin.y = screenRect.maxY + 4
            }
            // 右边不超出屏幕
            if origin.x + panelWidth > frame.maxX {
                origin.x = frame.maxX - panelWidth - 8
            }
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: panelWidth, height: idealHeight),
                       display: false)
    }

    @objc private func didClickPrevious() { onPrevious?() }
    @objc private func didClickNext() { onNext?() }
}
```

**Step 4: 运行验证通过**

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-task5 \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpPanelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：4 个测试全绿。

**Step 5: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorSignatureHelpPanel.swift \
        agentGuiTests/CodeEditorSignatureHelpPanelTests.swift
git commit -m "feat(l5): add CodeEditorSignatureHelpPanel NSPanel UI"
```

---

## Task 6：CodeEditorTextView — 集成安装与键盘事件

**目标：** 在 `CodeEditorTextView.Coordinator` 中安装签名帮助，连接 Trigger → Coordinator → Panel；在 `keyDown` 中处理 Esc（关闭）、`↑/↓`（切换重载）、`Cmd+Ctrl+Space`（手动触发）。

**Files:**
- Modify: `agentGui/Views/CodeEditor/CodeEditorTextView.swift`

> 无需新增独立测试 —— 此处仅是胶水代码，行为已被 Task 3/5 覆盖。

---

### Step 1: 在 `Coordinator` 中添加签名帮助属性

```swift
// agentGui/Views/CodeEditor/CodeEditorTextView.swift
// 在 completionPanel 属性声明附近添加：

private let signatureHelpTrigger = CodeEditorSignatureHelpTrigger()
private var signatureHelpPanel: CodeEditorSignatureHelpPanel?
```

---

### Step 2: 实现 `installSignatureHelp`

参照 `installCompletion` 方法模式：

```swift
// 在 Coordinator 中插入，放在 installCompletion 方法之后

func installSignatureHelp(for textView: CodeEditorPlatformTextView) {
    if signatureHelpPanel != nil { return }

    let panel = CodeEditorSignatureHelpPanel()
    signatureHelpPanel = panel

    panel.onNext = { [weak self] in self?.signatureHelpTrigger.next() }
    panel.onPrevious = { [weak self] in self?.signatureHelpTrigger.previous() }

    // Trigger → Coordinator → LSPClient 桥接
    signatureHelpTrigger.requestSignatureHelp = { [weak self] context, callback in
        guard let self,
              let tv = textView as? CodeEditorPlatformTextView,
              let coord = self.parent.lspCoordinator else {
            callback(nil)
            return
        }
        let sel = tv.selectedRange()
        let position = tv.codePosition(for: sel.location)
        coord.requestSignatureHelp(
            context: context,
            line: position.line,
            character: position.character,
            onResult: callback
        )
    }

    // 状态变化 → 显示或隐藏 panel
    signatureHelpTrigger.onSessionChange = { [weak self, weak textView, weak panel] help in
        guard let panel else { return }
        if let help {
            panel.update(help: help)
            if let tv = textView, let window = tv.window {
                let cursorRect = tv.convert(tv.cursorRect, to: nil)
                panel.show(anchoredBelow: cursorRect, in: window)
            }
        } else {
            panel.hide()
        }
        _ = self
    }
}
```

---

### Step 3: 在 `textDidChange` 中触发签名帮助

在已有的 completion trigger 代码块之后，添加签名帮助触发：

```swift
// 在 textDidChange 中，completion trigger block 之后插入：

// L5: Signature help trigger
if parent.isSignatureHelpEnabled,
   let lspCoordinator = parent.lspCoordinator,
   let caps = lspCoordinator.capabilities,
   caps.supportsSignatureHelp {
    signatureHelpTrigger.handleTyping(
        char: textView.lastTypedCharacter ?? "",
        cursorOffset: textView.selectedRange().location,
        triggerCharacters: caps.signatureHelpTriggerCharacters,
        retriggerCharacters: caps.signatureHelpRetriggerCharacters
    )
}
```

---

### Step 4: 在 `keyDown` 中处理签名帮助快捷键

在现有 completion panel key handling block 之后插入：

```swift
// L5: Signature help keyboard shortcuts
if signatureHelpTrigger.isActive {
    switch keyCode {
    case 53:   // Esc
        signatureHelpTrigger.cancel()
        return
    case 126:  // ↑
        if let panel = signatureHelpPanel, panel.isVisible {
            signatureHelpTrigger.previous()
            return
        }
    case 125:  // ↓
        if let panel = signatureHelpPanel, panel.isVisible {
            signatureHelpTrigger.next()
            return
        }
    default:
        break
    }
}
// Cmd+Ctrl+Space → 手动触发签名帮助
if modifiers == [.command, .control], keyCode == 49 /* Space */ {
    if parent.isSignatureHelpEnabled {
        let offset = (notification.object as? NSTextView)?.selectedRange().location ?? 0
        signatureHelpTrigger.invoke(cursorOffset: offset)
        return
    }
}
```

---

### Step 5: 在 `makeNSView`/`updateNSView` 中初始化

```swift
// 在已有的 installCompletion 调用之后追加：
if parent.isSignatureHelpEnabled {
    coordinator.installSignatureHelp(for: textView)
}
```

---

### Step 6: 给 `CodeEditorTextView` 添加 `isSignatureHelpEnabled` prop

```swift
// agentGui/Views/CodeEditor/CodeEditorTextView.swift 结构体中
var isSignatureHelpEnabled: Bool = false
```

---

### Step 7: 在 `CodeEditorSignatureHelpTrigger` 补充 `isActive` 计算属性

```swift
// 追加到 CodeEditorSignatureHelpTrigger
var isActive: Bool {
    if case .default = state { return false }
    return true
}
```

**Step 8: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-l5-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`，无 error。

**Step 9: Commit**

```bash
git add agentGui/Views/CodeEditor/CodeEditorTextView.swift \
        agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift
git commit -m "feat(l5): integrate signature help in CodeEditorTextView"
```

---

## Task 7：Capability 解析确认

**目标：** 确认 `LSPServerCapabilityHints` 已正确从 `initialize` 响应解析 `signatureHelpTriggerCharacters` / `signatureHelpRetriggerCharacters`。如果 Task 4 的代码在 `LSPServerCapabilities.swift` 中漏掉了解析，补上。

**Files:**
- Modify: `agentGui/Models/LSPServerCapabilities.swift`（如需补充解析）
- Modify: `agentGui/Services/LSP/LSPClient.swift`（`negotiatedCapabilities` 方法）

---

### Step 1: 检查现有解析代码

```bash
grep -n "signatureHelp" agentGui/Services/LSP/LSPClient.swift \
     agentGui/Models/LSPServerCapabilities.swift
```

找到 `negotiatedCapabilities(from:fallback:)` 或 `initializeSession` 中解析 capabilities 的位置。

---

### Step 2: 确认字段解析覆盖签名帮助

如果 `negotiatedCapabilities` 中缺少 signatureHelp 解析，在对应位置补充：

```swift
// 在解析 supportsCompletion 的代码块之后，查找并补充：

// Signature Help
if let sigHelpOptions = serverCaps["signatureHelpProvider"] as? [String: Any] {
    hints.supportsSignatureHelp = true
    hints.signatureHelpTriggerCharacters =
        (sigHelpOptions["triggerCharacters"] as? [String]) ?? ["(", ","]
    hints.signatureHelpRetriggerCharacters =
        (sigHelpOptions["retriggerCharacters"] as? [String]) ?? [",", ")"]
} else if serverCaps["signatureHelpProvider"] != nil {
    // 无选项的布尔值形式
    hints.supportsSignatureHelp = true
    hints.signatureHelpTriggerCharacters = ["(", ","]
    hints.signatureHelpRetriggerCharacters = [",", ")"]
}
```

**Step 3: 编译验证**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS \
  -derivedDataPath /tmp/agentGui-l5-task7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

**Step 4: Commit**

```bash
git add agentGui/Models/LSPServerCapabilities.swift \
        agentGui/Services/LSP/LSPClient.swift
git commit -m "feat(l5): parse signatureHelp server capabilities from initialize response"
```

---

## Task 8：端到端验收测试

**目标：** 运行所有 L5 相关测试，确认各层无回归。

**Files:**
- Test: 所有 L5 测试文件

---

### Step 1: 一次性运行所有 L5 测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-final \
  -only-testing:agentGuiTests/LSPSignatureHelpModelsTests \
  -only-testing:agentGuiTests/LSPClientSignatureHelpParsingTests \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpTriggerTests \
  -only-testing:agentGuiTests/CoordinatorSignatureHelpIntegrationTests \
  -only-testing:agentGuiTests/CodeEditorSignatureHelpPanelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：所有测试绿色，`Test Suite 'Selected tests' passed`。

---

### Step 2: 运行 smoke test 确认无回归

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination platform=macOS -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-l5-smoke \
  -only-testing:agentGuiTests/CodeEditorCompletionPanelTests \
  -only-testing:agentGuiTests/CodeEditorCompletionTriggerTests \
  -only-testing:agentGuiTests/CodeEditorLSPCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：现有补全 + LSP 协调器测试无回归。

---

### Step 3: 手动验收清单（需要运行 app + pylsp）

| 场景 | 操作 | 预期结果 |
|------|------|----------|
| 基础触发 | Python 文件输入 `print(` | 浮层出现，显示 `print(*objects, sep=' ', end='\n', file=None, flush=False)` |
| 参数高亮 | 已在括号内，输入 `, ` | 高亮位置移动到第 2 个参数 |
| 重载切换 | TypeScript 重载函数输入 `(` | 浮层显示 `1/N`，↑↓ 键切换 |
| 取消 | 浮层可见时按 `Esc` | 浮层立即消失 |
| 鼠标取消 | 鼠标点击其他位置 | 浮层消失 |
| 手动触发 | 光标在参数中手动按 `Cmd+Ctrl+Space` | 浮层重新出现 |
| 下方空间不足 | 光标接近屏幕底部 | 浮层翻转到光标上方 |

**Step 4: Final Commit**

```bash
git add -A
git commit -m "feat(l5): signature help complete - trigger, panel, coordinator integration"
```

---

## 变更文件汇总

| 文件 | 操作 | 说明 |
|------|------|------|
| `agentGui/Models/LSPSignatureHelpModels.swift` | Create | 数据模型 + parser |
| `agentGui/Services/LSP/LSPClient.swift` | Modify | 新增 `signatureHelp` 方法 |
| `agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift` | Create | 三态触发状态机 |
| `agentGui/Services/Editor/CodeEditorLSPCoordinator.swift` | Modify | 新增 `requestSignatureHelp` / `cancelSignatureHelp` |
| `agentGui/Views/CodeEditor/CodeEditorSignatureHelpPanel.swift` | Create | NSPanel 浮层 UI |
| `agentGui/Views/CodeEditor/CodeEditorTextView.swift` | Modify | 安装 + keyDown + textDidChange 集成 |
| `agentGui/Models/LSPServerCapabilities.swift` | Modify | 补充 signatureHelp capability 解析 |
| `agentGuiTests/LSPSignatureHelpModelsTests.swift` | Create | 模型+解析测试 |
| `agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift` | Create | 状态机测试(含集成) |
| `agentGuiTests/CodeEditorSignatureHelpPanelTests.swift` | Create | Panel UI 测试 |
