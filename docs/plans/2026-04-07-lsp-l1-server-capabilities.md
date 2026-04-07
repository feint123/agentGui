# Feature L-1: 实际 ServerCapabilities 协商 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 解析 LSP `initialize` 响应中的真实 `ServerCapabilities`，替换静态 `capabilityHints`，动态控制 completion / signatureHelp / codeAction / formatting / rename 等功能开关，并完善 `clientCapabilities` 声明让服务器知晓客户端支持范围。

**Architecture:** 扩展 `LSPServerCapabilityHints`（位于 `Models/LSPServerCapabilities.swift`）新增所有 LSP 3.17 标准能力字段；在 `LSPClient.negotiatedCapabilities` 中解析对应字段；修复 `initializeParams` 的 `capabilities` 字典以声明完整的客户端能力。所有变更均遵循 VSCode `src/vs/editor/contrib/` 中各 feature 注册 serverCapabilities 的约定。

**Tech Stack:** Swift 6.0+, Swift Testing framework (`import Testing`), `@testable import agentGui`

---

## 参考：VSCode serverCapabilities 映射

VSCode `ILanguageFeaturesService` 与 LSP 3.17 `ServerCapabilities` 字段对应：

| VSCode Provider | LSP `ServerCapabilities` 字段 |
|---|---|
| completionProvider | `completionProvider: CompletionOptions` |
| signatureHelpProvider | `signatureHelpProvider: SignatureHelpOptions` |
| codeActionProvider | `codeActionProvider: bool \| CodeActionOptions` |
| documentFormattingProvider | `documentFormattingProvider: bool \| DocumentFormattingOptions` |
| documentRangeFormattingProvider | `documentRangeFormattingProvider: bool \| DocumentRangeFormattingOptions` |
| onTypeFormattingProvider | `documentOnTypeFormattingProvider: DocumentOnTypeFormattingOptions` |
| renameProvider | `renameProvider: bool \| RenameOptions` |
| documentHighlightProvider | `documentHighlightProvider: bool \| DocumentHighlightOptions` |
| semanticTokensProvider | `semanticTokensProvider: SemanticTokensOptions` |
| inlayHintsProvider | `inlayHintProvider: bool \| InlayHintOptions` |
| foldingRangeProvider | `foldingRangeProvider: bool \| FoldingRangeOptions` |
| declarationProvider | `declarationProvider: bool \| DeclarationOptions` |
| typeDefinitionProvider | `typeDefinitionProvider: bool \| TypeDefinitionOptions` |
| implementationProvider | `implementationProvider: bool \| ImplementationOptions` |
| selectionRangeProvider | `selectionRangeProvider: bool \| SelectionRangeOptions` |

---

## Task L1-T1: 扩展 `LSPServerCapabilityHints` 模型

**目的**：增加 Feature L-2 至 L-9 需要的能力字段，保持向后兼容。

**Files:**
- Modify: `agentGui/Models/LSPServerCapabilities.swift`
- Create: `agentGuiTests/LSPServerCapabilitiesTests.swift`

---

### Step 1: 新建测试文件，写第一批失败断言

新建 `agentGuiTests/LSPServerCapabilitiesTests.swift`：

```swift
import Testing
@testable import agentGui

struct LSPServerCapabilitiesTests {

    // MARK: - Field defaults

    @Test func readOnlySemanticDefaultsMissingNewFields() {
        let h = LSPServerCapabilityHints.readOnlySemanticDefaults
        // 以下字段尚不存在，编译失败即代表测试"失败"
        #expect(h.supportsCompletion == false)
        #expect(h.completionTriggerCharacters == [])
        #expect(h.supportsSignatureHelp == false)
        #expect(h.signatureHelpTriggerCharacters == [])
        #expect(h.signatureHelpRetriggerCharacters == [])
        #expect(h.supportsCodeActions == false)
        #expect(h.supportsDocumentFormatting == false)
        #expect(h.supportsRangeFormatting == false)
        #expect(h.supportsOnTypeFormatting == false)
        #expect(h.onTypeFormattingTriggerCharacters == [])
        #expect(h.supportsRename == false)
        #expect(h.supportsPrepareRename == false)
        #expect(h.supportsDocumentHighlights == false)
        #expect(h.supportsDeclaration == false)
        #expect(h.supportsTypeDefinition == false)
        #expect(h.supportsImplementation == false)
        #expect(h.supportsFoldingRange == false)
        #expect(h.supportsSemanticTokens == false)
        #expect(h.supportsInlayHints == false)
    }
}
```

### Step 2: 运行测试，确认编译错误

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：编译错误，类似 `value of type 'LSPServerCapabilityHints' has no member 'supportsCompletion'`

### Step 3: 在 `LSPServerCapabilities.swift` 中扩展结构体

在 `supportsDiagnostics` 字段后添加新字段，**全部设置默认值 = false / []** 以保持向后兼容：

```swift
struct LSPServerCapabilityHints: Codable, Hashable, Sendable {
    // — 已有字段 —
    var supportsHover: Bool
    var supportsDefinition: Bool
    var supportsReferences: Bool
    var supportsDocumentSymbols: Bool
    var supportsWorkspaceSymbols: Bool
    var supportsDiagnostics: Bool

    // — L-4 Completion —
    var supportsCompletion: Bool = false
    var completionTriggerCharacters: [String] = []

    // — L-5 Signature Help —
    var supportsSignatureHelp: Bool = false
    var signatureHelpTriggerCharacters: [String] = []
    var signatureHelpRetriggerCharacters: [String] = []

    // — L-6 Code Actions —
    var supportsCodeActions: Bool = false

    // — L-7 Formatting —
    var supportsDocumentFormatting: Bool = false
    var supportsRangeFormatting: Bool = false
    var supportsOnTypeFormatting: Bool = false
    var onTypeFormattingTriggerCharacters: [String] = []

    // — L-8 Rename —
    var supportsRename: Bool = false
    var supportsPrepareRename: Bool = false

    // — L-9 Document Highlights —
    var supportsDocumentHighlights: Bool = false

    // — Declaration / TypeDefinition / Implementation —
    var supportsDeclaration: Bool = false
    var supportsTypeDefinition: Bool = false
    var supportsImplementation: Bool = false

    // — Folding Range —
    var supportsFoldingRange: Bool = false

    // — Semantic Tokens —
    var supportsSemanticTokens: Bool = false

    // — Inlay Hints —
    var supportsInlayHints: Bool = false

    static let readOnlySemanticDefaults = LSPServerCapabilityHints(
        supportsHover: true,
        supportsDefinition: true,
        supportsReferences: true,
        supportsDocumentSymbols: true,
        supportsWorkspaceSymbols: true,
        supportsDiagnostics: true
    )
}
```

> **注意**：保留原来的六参数 memberwise initializer 签名不变（新字段有默认值），`readOnlySemanticDefaults` 无需修改。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed|error"
```

期望：`Test Suite 'LSPServerCapabilitiesTests' passed`

### Step 5: Commit

```bash
git add agentGui/Models/LSPServerCapabilities.swift \
        agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "feat(lsp-l1): L1-T1 extend LSPServerCapabilityHints with new capability fields"
```

---

## Task L1-T2: 扩展 `negotiatedCapabilities` 解析新字段

**目的**：`LSPClient.negotiatedCapabilities` 解析 `initialize` 响应中所有新增能力字段。

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`（`negotiatedCapabilities` 私有方法，约 209 行起）
- Modify: `agentGuiTests/LSPServerCapabilitiesTests.swift`（追加解析测试）

---

### Step 1: 在测试文件中追加解析测试

在 `LSPServerCapabilitiesTests.swift` 末尾添加：

```swift
    // MARK: - negotiatedCapabilities parsing

    @Test func parsesCompletionProviderAsObject() {
        let raw: [String: Any] = [
            "capabilities": [
                "completionProvider": [
                    "triggerCharacters": [".", "(", ","],
                    "resolveProvider": true
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == true)
        #expect(result.completionTriggerCharacters == [".", "(", ","])
    }

    @Test func parsesCompletionProviderAsBoolTrue() {
        let raw: [String: Any] = ["capabilities": ["completionProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == true)
        #expect(result.completionTriggerCharacters == [])
    }

    @Test func parsesCompletionProviderAsBoolFalse() {
        let raw: [String: Any] = ["capabilities": ["completionProvider": false]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == false)
    }

    @Test func parsesSignatureHelpProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "signatureHelpProvider": [
                    "triggerCharacters": ["(", ","],
                    "retriggerCharacters": [")"]
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsSignatureHelp == true)
        #expect(result.signatureHelpTriggerCharacters == ["(", ","])
        #expect(result.signatureHelpRetriggerCharacters == [")"])
    }

    @Test func parsesCodeActionProviderAsBool() {
        let raw: [String: Any] = ["capabilities": ["codeActionProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCodeActions == true)
    }

    @Test func parsesCodeActionProviderAsObject() {
        let raw: [String: Any] = [
            "capabilities": ["codeActionProvider": ["codeActionKinds": ["quickfix", "refactor"]]]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCodeActions == true)
    }

    @Test func parsesDocumentFormattingProvider() {
        let raw: [String: Any] = ["capabilities": ["documentFormattingProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDocumentFormatting == true)
    }

    @Test func parsesDocumentRangeFormattingProvider() {
        let raw: [String: Any] = ["capabilities": ["documentRangeFormattingProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRangeFormatting == true)
    }

    @Test func parsesOnTypeFormattingProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "documentOnTypeFormattingProvider": [
                    "firstTriggerCharacter": ":",
                    "moreTriggerCharacter": ["{", "}"]
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsOnTypeFormatting == true)
        #expect(result.onTypeFormattingTriggerCharacters.contains(":"))
        #expect(result.onTypeFormattingTriggerCharacters.contains("{"))
    }

    @Test func parsesRenameProviderAsBool() {
        let raw: [String: Any] = ["capabilities": ["renameProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRename == true)
        #expect(result.supportsPrepareRename == false)
    }

    @Test func parsesRenameProviderWithPrepareRename() {
        let raw: [String: Any] = [
            "capabilities": ["renameProvider": ["prepareProvider": true]]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsRename == true)
        #expect(result.supportsPrepareRename == true)
    }

    @Test func parsesDocumentHighlightProvider() {
        let raw: [String: Any] = ["capabilities": ["documentHighlightProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDocumentHighlights == true)
    }

    @Test func parsesTypeDefinitionAndImplementationProviders() {
        let raw: [String: Any] = [
            "capabilities": [
                "typeDefinitionProvider": true,
                "implementationProvider": ["id": "impl"]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsTypeDefinition == true)
        #expect(result.supportsImplementation == true)
    }

    @Test func parsesDeclarationProvider() {
        let raw: [String: Any] = ["capabilities": ["declarationProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsDeclaration == true)
    }

    @Test func parsesFoldingRangeProvider() {
        let raw: [String: Any] = ["capabilities": ["foldingRangeProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsFoldingRange == true)
    }

    @Test func parsesSemanticTokensProvider() {
        let raw: [String: Any] = [
            "capabilities": [
                "semanticTokensProvider": [
                    "legend": ["tokenTypes": ["namespace"], "tokenModifiers": []],
                    "full": true
                ]
            ]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsSemanticTokens == true)
    }

    @Test func parsesInlayHintProvider() {
        let raw: [String: Any] = ["capabilities": ["inlayHintProvider": true]]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsInlayHints == true)
    }

    @Test func missingCapabilitiesKeepFallback() {
        // 服务器未声明 completionProvider → 取 fallback 值 false
        let raw: [String: Any] = [
            "capabilities": ["hoverProvider": true]
        ]
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: .allDisabled)
        #expect(result.supportsCompletion == false)
    }

    @Test func malformedCapabilitiesObjectFallsBackCompletely() {
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: nil, fallback: .allDisabled)
        #expect(result.supportsHover == false)
        #expect(result.supportsCompletion == false)
    }
```

还需要在 `LSPServerCapabilityHints` 扩展中添加测试专用的 `.allDisabled` 静态属性（与 `readOnlySemanticDefaults` 并列，在 `LSPServerCapabilities.swift` 末尾追加）：

```swift
// 仅供测试——所有能力均关闭，方便断言单个字段
extension LSPServerCapabilityHints {
    static let allDisabled = LSPServerCapabilityHints(
        supportsHover: false,
        supportsDefinition: false,
        supportsReferences: false,
        supportsDocumentSymbols: false,
        supportsWorkspaceSymbols: false,
        supportsDiagnostics: false
    )
}
```

### Step 2: 在 `LSPClient` 添加测试可见入口

测试需直接调用 `negotiatedCapabilities`（当前是 `private`）。在 `LSPClient.swift` 中将其访问级别改为 `package` 或添加 `#if DEBUG` 测试入口。推荐用最简洁方式：在文件末尾添加 `internal static` 测试钩子（Swift Testing 通过 `@testable` 访问 internal）：

```swift
// 测试钩子——使 negotiatedCapabilities 可通过 @testable 访问
extension LSPClient {
    static func negotiatedCapabilitiesForTesting(
        from rawResult: Any?,
        fallback: LSPServerCapabilityHints
    ) -> LSPServerCapabilityHints {
        let dummy = LSPClient(
            transport: LSPJSONRPCTransport(),
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: NoOpLSPAdapter()
        )
        return dummy.negotiatedCapabilities(from: rawResult, fallback: fallback)
    }
}
```

同时需要一个最小 `NoOpLSPAdapter`，在与测试钩子同文件（文件末尾）或独立文件中添加：

```swift
// 仅供测试用的空 adapter
private final class NoOpLSPAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        .allDisabled
    }
}
```

> **提醒**：检查 `LSPServerAdapter` 协议定义（`agentGui/Services/LSP/LSPServerAdapter.swift`），确认方法签名一致后再填写上方代码。

### Step 3: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "failed|error|passed"
```

期望：多个测试失败，例如 `parsesCompletionProviderAsObject — supportsCompletion: false is not true`

### Step 4: 扩展 `negotiatedCapabilities` 实现

将 `LSPClient.negotiatedCapabilities` 替换为以下完整实现：

```swift
private func negotiatedCapabilities(
    from rawResult: Any?,
    fallback: LSPServerCapabilityHints
) -> LSPServerCapabilityHints {
    guard let object = rawResult as? [String: Any],
          let capabilities = object["capabilities"] as? [String: Any] else {
        return fallback
    }

    // —— 辅助：从 triggerCharacters 数组提取字符串 ——
    func triggerChars(_ key: String, in opts: [String: Any]) -> [String] {
        (opts[key] as? [String]) ?? []
    }

    // completion
    let completionOpts = capabilities["completionProvider"] as? [String: Any]
    let supportsCompletion: Bool = completionOpts != nil
        || (capabilities["completionProvider"] as? Bool ?? false)
    let completionTriggers: [String] = completionOpts.map { triggerChars("triggerCharacters", in: $0) } ?? []

    // signatureHelp
    let sigOpts = capabilities["signatureHelpProvider"] as? [String: Any]
    let supportsSignatureHelp = sigOpts != nil || (capabilities["signatureHelpProvider"] as? Bool ?? false)
    let sigTriggers: [String] = sigOpts.map { triggerChars("triggerCharacters", in: $0) } ?? []
    let sigRetriggers: [String] = sigOpts.map { triggerChars("retriggerCharacters", in: $0) } ?? []

    // onTypeFormatting — firstTriggerCharacter + moreTriggerCharacter
    var onTypeTriggers: [String] = []
    var supportsOnTypeFormatting = false
    if let onTypeOpts = capabilities["documentOnTypeFormattingProvider"] as? [String: Any] {
        supportsOnTypeFormatting = true
        if let first = onTypeOpts["firstTriggerCharacter"] as? String {
            onTypeTriggers.append(first)
        }
        if let more = onTypeOpts["moreTriggerCharacter"] as? [String] {
            onTypeTriggers.append(contentsOf: more)
        }
    }

    // rename — bool | { prepareProvider: bool }
    let renameRaw = capabilities["renameProvider"]
    let supportsRename: Bool = (renameRaw as? Bool) ?? (renameRaw is [String: Any])
    let supportsPrepareRename: Bool = (renameRaw as? [String: Any])?["prepareProvider"] as? Bool ?? false

    return LSPServerCapabilityHints(
        supportsHover: boolCapability(capabilities["hoverProvider"], fallback: fallback.supportsHover),
        supportsDefinition: boolCapability(capabilities["definitionProvider"], fallback: fallback.supportsDefinition),
        supportsReferences: boolCapability(capabilities["referencesProvider"], fallback: fallback.supportsReferences),
        supportsDocumentSymbols: boolCapability(capabilities["documentSymbolProvider"], fallback: fallback.supportsDocumentSymbols),
        supportsWorkspaceSymbols: boolCapability(
            capabilities["workspaceSymbolProvider"] ?? (capabilities["workspace"] as? [String: Any])?["symbolProvider"],
            fallback: fallback.supportsWorkspaceSymbols
        ),
        supportsDiagnostics: boolCapability(
            capabilities["diagnosticProvider"],
            fallback: fallback.supportsDiagnostics
        ),
        supportsCompletion: supportsCompletion,
        completionTriggerCharacters: completionTriggers,
        supportsSignatureHelp: supportsSignatureHelp,
        signatureHelpTriggerCharacters: sigTriggers,
        signatureHelpRetriggerCharacters: sigRetriggers,
        supportsCodeActions: boolCapability(capabilities["codeActionProvider"], fallback: fallback.supportsCodeActions),
        supportsDocumentFormatting: boolCapability(capabilities["documentFormattingProvider"], fallback: fallback.supportsDocumentFormatting),
        supportsRangeFormatting: boolCapability(capabilities["documentRangeFormattingProvider"], fallback: fallback.supportsRangeFormatting),
        supportsOnTypeFormatting: supportsOnTypeFormatting,
        onTypeFormattingTriggerCharacters: onTypeTriggers,
        supportsRename: supportsRename,
        supportsPrepareRename: supportsPrepareRename,
        supportsDocumentHighlights: boolCapability(capabilities["documentHighlightProvider"], fallback: fallback.supportsDocumentHighlights),
        supportsDeclaration: boolCapability(capabilities["declarationProvider"], fallback: fallback.supportsDeclaration),
        supportsTypeDefinition: boolCapability(capabilities["typeDefinitionProvider"], fallback: fallback.supportsTypeDefinition),
        supportsImplementation: boolCapability(capabilities["implementationProvider"], fallback: fallback.supportsImplementation),
        supportsFoldingRange: boolCapability(capabilities["foldingRangeProvider"], fallback: fallback.supportsFoldingRange),
        supportsSemanticTokens: (capabilities["semanticTokensProvider"] as? [String: Any]) != nil,
        supportsInlayHints: boolCapability(capabilities["inlayHintProvider"], fallback: fallback.supportsInlayHints)
    )
}
```

> **注意**：`LSPServerCapabilityHints` 的 memberwise initializer 现在字段很多，编译器会自动生成。用具名参数列表按顺序对应结构体字段声明顺序即可。

### Step 5: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

期望：`Test Suite 'LSPServerCapabilitiesTests' passed`

### Step 6: Commit

```bash
git add agentGui/Models/LSPServerCapabilities.swift \
        agentGui/Services/LSP/LSPClient.swift \
        agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "feat(lsp-l1): L1-T2 parse all ServerCapabilities fields in negotiatedCapabilities"
```

---

## Task L1-T3: 修复 `initializeParams` 的 `clientCapabilities`

**目的**：将 `capabilities.textDocument` 和 `capabilities.workspace` 填写完整，让服务器知晓客户端支持的能力范围（遵循 VSCode `extensionHostMain.ts` 中 `clientCapabilities` 构造模式）。

**Files:**
- Modify: `agentGui/Services/LSP/LSPClient.swift`（`initializeParams` 方法，约 187 行起）
- Modify: `agentGuiTests/LSPServerCapabilitiesTests.swift`（追加一个 initializeParams 参数检查测试）

---

### Step 1: 写 `initializeParams` 结构验证测试

在 `LSPServerCapabilitiesTests.swift` 新增一个 `struct`（或在同文件追加）：

```swift
struct LSPClientCapabilitiesParamsTests {

    @Test func initializeParamsContainsTextDocumentCapabilities() throws {
        let client = LSPClient(
            transport: LSPJSONRPCTransport(),
            documentStore: LSPDocumentStore(),
            diagnosticsStore: LSPDiagnosticsStore(),
            adapter: NoOpLSPAdapter()
        )
        let params = client.initializeParamsForTesting(workspaceRoot: "/tmp/test")
        let caps = try #require(params["capabilities"] as? [String: Any])
        let textDoc = try #require(caps["textDocument"] as? [String: Any])
        let workspace = try #require(caps["workspace"] as? [String: Any])

        // textDocument 至少声明 hover / completion / signatureHelp / codeAction
        #expect(textDoc["hover"] != nil)
        #expect(textDoc["completion"] != nil)
        #expect(textDoc["signatureHelp"] != nil)
        #expect(textDoc["codeAction"] != nil)
        #expect(textDoc["rename"] != nil)
        #expect(textDoc["formatting"] != nil)

        // workspace 声明 applyEdit（L-6/L-8 需要）
        let applyEdit = try #require(workspace["applyEdit"] as? Bool)
        #expect(applyEdit == true)
    }
}
```

同样需要测试钩子暴露 `initializeParams`：

```swift
extension LSPClient {
    func initializeParamsForTesting(workspaceRoot: String) -> [String: Any] {
        initializeParams(workspaceRoot: workspaceRoot)
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "initializeParams|failed|passed"
```

期望：`initializeParamsContainsTextDocumentCapabilities — … is nil` 失败

### Step 3: 替换 `initializeParams` 实现

将 `LSPClient.initializeParams` 中的 `capabilities` 字典替换为：

```swift
"capabilities": [
    "workspace": [
        "applyEdit": true,
        "workspaceEdit": [
            "documentChanges": true
        ],
        "symbol": [
            "symbolKind": [
                "valueSet": Array(1...26)   // SymbolKind 全集
            ]
        ]
    ],
    "textDocument": [
        "synchronization": [
            "dynamicRegistration": false,
            "willSave": false,
            "didSave": true
        ],
        "hover": [
            "contentFormat": ["markdown", "plaintext"]
        ],
        "completion": [
            "completionItem": [
                "snippetSupport": false,
                "documentationFormat": ["markdown", "plaintext"],
                "insertReplaceSupport": true
            ],
            "contextSupport": true
        ],
        "signatureHelp": [
            "signatureInformation": [
                "documentationFormat": ["markdown", "plaintext"],
                "parameterInformation": ["labelOffsetSupport": true]
            ],
            "contextSupport": true
        ],
        "definition": ["linkSupport": false],
        "declaration": ["linkSupport": false],
        "typeDefinition": ["linkSupport": false],
        "implementation": ["linkSupport": false],
        "references": [:],
        "documentHighlight": [:],
        "documentSymbol": [
            "hierarchicalDocumentSymbolSupport": true,
            "symbolKind": ["valueSet": Array(1...26)]
        ],
        "codeAction": [
            "codeActionLiteralSupport": [
                "codeActionKind": [
                    "valueSet": ["", "quickfix", "refactor", "refactor.extract",
                                 "refactor.inline", "refactor.rewrite",
                                 "source", "source.organizeImports"]
                ]
            ],
            "resolveSupport": ["properties": ["edit"]]
        ],
        "rename": [
            "prepareSupport": true
        ],
        "formatting": [:],
        "rangeFormatting": [:],
        "onTypeFormatting": [:],
        "foldingRange": [
            "rangeLimit": 5000,
            "lineFoldingOnly": true
        ],
        "semanticTokens": [
            "requests": ["full": true, "range": false],
            "tokenTypes": [],
            "tokenModifiers": [],
            "formats": ["relative"],
            "multilineTokenSupport": false
        ],
        "inlayHint": [
            "resolveSupport": ["properties": ["tooltip", "textEdits", "label.tooltip"]]
        ],
        "publishDiagnostics": [
            "relatedInformation": true,
            "versionSupport": true,
            "tagSupport": ["valueSet": [1, 2]]
        ]
    ]
]
```

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

期望：全部通过

### Step 5: Commit

```bash
git add agentGui/Services/LSP/LSPClient.swift \
        agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "feat(lsp-l1): L1-T3 declare full clientCapabilities in initializeParams"
```

---

## Task L1-T4: `supportsDiagnostics` 解析修复 + 全量回归

**目的**：`supportsDiagnostics` 当前硬编码取 fallback。LSP 3.17 中服务器通过 `diagnosticProvider` 声明支持 pull 诊断，与 push 模式（`publishDiagnostics`）并存。确保字段正确解析并运行完整 LSP 相关测试。

**Files:**
- 已在 Task L1-T2 的实现中修复（`boolCapability(capabilities["diagnosticProvider"], fallback: ...)` 替代硬编码 fallback）
- Modify: `agentGuiTests/LSPServerCapabilitiesTests.swift`（追加 diagnosticProvider 解析测试）
- Run: 已有 `LSPDiagnosticsParsingTests` 确保无回归

---

### Step 1: 追加 diagnosticProvider 测试

在 `LSPServerCapabilitiesTests.swift` 中追加：

```swift
    @Test func parsesDiagnosticProviderAsObject() {
        // pull 诊断服务器声明 diagnosticProvider
        let raw: [String: Any] = [
            "capabilities": [
                "diagnosticProvider": [
                    "identifier": "pylsp",
                    "interFileDependencies": false,
                    "workspaceDiagnostics": false
                ]
            ]
        ]
        let fallback = LSPServerCapabilityHints.allDisabled
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: fallback)
        #expect(result.supportsDiagnostics == true)
    }

    @Test func diagnosticsDefaultFallbackWhenProviderAbsent() {
        // 服务器不声明 diagnosticProvider（用 push 模式）→ fallback true
        let raw: [String: Any] = ["capabilities": ["hoverProvider": true]]
        var fallback = LSPServerCapabilityHints.allDisabled
        fallback.supportsDiagnostics = true
        let result = LSPClient.negotiatedCapabilitiesForTesting(from: raw, fallback: fallback)
        #expect(result.supportsDiagnostics == true)
    }
```

### Step 2: 运行全量 LSP 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -only-testing:agentGuiTests/LSPDiagnosticsParsingTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

期望：两个套件均通过

### Step 3: Commit

```bash
git add agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "test(lsp-l1): L1-T4 diagnosticProvider parsing + regression guard"
```

---

## Task L1-T5: `LSPToolFacade` 与 `CodeEditorLSPCoordinator` 能力门控检查

**目的**：`LSPToolFacade` 的 hover/definition/references 工具调用已经隐式依赖能力，但没有显式 guard；若服务器未声明某能力应返回明确错误而非让请求超时。同时确保 `CodeEditorLSPCoordinator` 读取真实 capabilities 而非 hardcoded。

**Files:**
- Modify: `agentGui/Services/LSP/LSPToolFacade.swift`（hover / definition / references 各方法首行增加能力检查）
- Read: `agentGui/Services/LSP/CodeEditorLSPCoordinator.swift`（确认当前是否已做能力门控，若无则添加）
- Modify: `agentGuiTests/LSPServerCapabilitiesTests.swift`（追加 facade guard 测试，如工程已有 LSPToolFacadeTests 则在其中追加）

---

### Step 1: 阅读 `LSPToolFacade.swift` 中现有守卫逻辑

```bash
grep -n "capabilities\|guard\|supportsHover\|supportsDefinition" \
  agentGui/Services/LSP/LSPToolFacade.swift | head -40
```

若已有 `guard capabilities.supportsHover else { throw ... }`，此 Task 可直接跳到 Step 4 进行回归验证。

### Step 2: 添加能力门控（若 facade 缺失）

在 `LSPToolFacade.hover(...)` 首行增加：

```swift
guard client.capabilities?.supportsHover == true else {
    throw LSPToolError.capabilityNotSupported("hover")
}
```

对 `definition`、`references`、`documentSymbols` 类似处理。确认 `LSPToolError` 是否已有 `capabilityNotSupported` case，若无则添加一个。

### Step 3: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/LSPServerCapabilitiesTests \
  -only-testing:agentGuiTests/LSPDiagnosticsParsingTests \
  -derivedDataPath /tmp/agentGui-lsp-l1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|passed|failed"
```

### Step 4: Commit

```bash
git add agentGui/Services/LSP/LSPToolFacade.swift \
        agentGui/Services/LSP/CodeEditorLSPCoordinator.swift \
        agentGuiTests/LSPServerCapabilitiesTests.swift
git commit -m "feat(lsp-l1): L1-T5 capability guards in LSPToolFacade and CodeEditorLSPCoordinator"
```

---

## 验收检查清单

完成所有 Task 后，手动验证以下场景：

| # | 场景 | 期望结果 |
|---|------|---------|
| 1 | 启动 pylsp + Python 文件 | `capabilities.supportsCompletion == true`，`completionTriggerCharacters` 含 `.` |
| 2 | 启动 clangd + C++ 文件 | `supportsSignatureHelp == true`，`signatureHelpTriggerCharacters` 含 `(` |
| 3 | 启动 gopls + Go 文件 | `supportsRename == true`、`supportsPrepareRename == true` |
| 4 | 日志中 `initialize` 请求 | `capabilities.textDocument.completion` 等字段已声明 |
| 5 | hover on unsupported server | `LSPToolFacade.hover` 抛出 `capabilityNotSupported` 而非超时 |

---

## 相关参考

- VSCode `src/vs/editor/common/services/languageFeatures.ts` — `ILanguageFeaturesService` provider 注册表
- LSP 3.17 规范 §3.15 `ServerCapabilities` — https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#serverCapabilities
- 本项目设计文档：`docs/plans/2026-04-07-lsp-iteration-design.md`
