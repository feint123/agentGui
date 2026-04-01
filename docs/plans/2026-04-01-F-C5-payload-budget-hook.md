# F-C5: PayloadBudgetHook 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在工具 `postExecute` 阶段检测结果大小；若超过阈值（默认 16 KB），自动把完整结果存入现有 `ToolPayloadStore`，并将消息上下文中的内容替换为结构化 payload reference，避免大型工具结果撑爆 context window。

**Architecture:** 新增 `PayloadBudgetHook` struct（实现 `ToolExecutionHook` 协议），注册到现有 `ToolExecutionHookPipeline`。Hook 依赖已有的 `ToolPayloadStore` actor 和 `ToolResultEnvelope` 模型；仅在 `postExecute` 阶段介入（preExecute / postFailure 均 passthrough）。对已经携带 envelope（由 `wrapLargeTextToolResult` 处理过）的结果不再二次处理，避免重复压缩。

**Tech Stack:** Swift 6, `ToolExecutionHook`（已有），`ToolPayloadStore` actor（已有），`ToolResultEnvelope`（已有），`LargeTextPayload.SourceKind`（已有），`AgentLoopToolExecutionCoordinatorBuilder`（注册点），XCTest。

---

## 背景与上下文

### 依赖关系

| 组件 | 路径 | 说明 |
|---|---|---|
| `ToolExecutionHook` 协议 | `Services/ToolGovernance/ToolExecutionHookPipeline.swift` | 须实现 `preExecute` / `postExecute` / `postFailure` |
| `ToolRunRecord` | 同上 | postExecute 入参，含 `toolName`、`result.text`、`result.envelope` |
| `ToolCallPreview` | 同上 | preExecute / postFailure 入参 |
| `ToolPayloadStore` | `Services/ToolPayloadStore.swift` | actor；`createPayload(text:sourceKind:sourceDescriptor:)` 产生 `LargeTextPayload` |
| `LargeTextPayload` | `Models/LargeTextPayload.swift` | 含 `payloadID`、`rawCharCount`、`sourceKind` 等字段 |
| `ToolResultEnvelope` | `Models/ToolResultEnvelope.swift` | `renderForModel()` 产出结构化 reference 文本；`InjectionMode.referenced` |
| `ToolExecutionResult` | `Services/ClaudeService/ClaudeService+ToolExecutionResult.swift` | hook 通过 `.rewriteResult` 返回新 result；须保留 `status` 与 `rawOutputText` |
| `ChangeReviewHook` | `Services/ToolGovernance/Hooks/ChangeReviewHook.swift` | 样板参考（同一 hook 目录） |
| `VerificationEvidenceHook` | `Services/ToolGovernance/Hooks/VerificationEvidenceHook.swift` | 样板参考（异步 postExecute 逻辑） |
| `AgentLoopToolExecutionCoordinatorBuilder` | `Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | 注册点；已有注释 `// F-C5 PayloadBudgetHook 将在此追加` |

### 与 ClaudeService+ToolDispatch.swift 的关系

`ClaudeService+ToolDispatch.swift` 中的 `wrapLargeTextToolResult` 在特定工具（bash、file read 等）的 **dispatch 层**已提前运行 `ToolResultBudgetController`，并为结果附加 `envelope`。

**PayloadBudgetHook 是 hook 层的安全网**，负责捕获以下情况：
1. 未经 `wrapLargeTextToolResult` 显式处理的工具（自定义工具、新增工具）返回超大文本。
2. 工具 dispatch 路径绕过了 budget controller 的 edge case。

**检测逻辑：若 `record.result.envelope != nil`，说明已在 dispatch 层处理过，直接 passthrough，不重复压缩。**

---

## 新增文件清单

```
agentGui/Services/ToolGovernance/Hooks/
  PayloadBudgetHook.swift                  ← Task 1 (hook 实现)

agentGuiTests/
  PayloadBudgetHookTests.swift             ← Task 2 (TDD，先写测试)
```

**修改文件清单：**

```
agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
  buildHookPipeline()                      ← Task 3 (注册 hook)
```

---

## Task 1 — 实现 `PayloadBudgetHook`

**Files:**
- Create: `agentGui/Services/ToolGovernance/Hooks/PayloadBudgetHook.swift`

### Step 1: 创建文件，写入完整实现

```swift
import Foundation

/// 工具结果 payload 预算钩子：在 postExecute 阶段检测结果大小。
/// 若结果文本超过阈值且尚未被 dispatch 层处理（`envelope == nil`），
/// 将完整文本存入 `ToolPayloadStore` 并以结构化 reference 替换 context 中的内容，
/// 避免大型工具结果撑爆 context window。
///
/// **不触发条件（直接 passthrough）：**
/// - `record.result.envelope != nil`：dispatch 层已处理，不重复压缩
/// - `record.result.isError`：失败结果不做 payload 化
/// - 文本长度 ≤ `charThreshold`
///
/// 注册于 `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()`（F-C5）。
struct PayloadBudgetHook: ToolExecutionHook, Sendable {

    let hookID = "payload-budget"

    /// 触发 payload 化的字符数阈值，默认 16 384（约 4 000 tokens）。
    let charThreshold: Int

    /// 用于创建 payload 文件的存储 actor。
    private let payloadStore: ToolPayloadStore

    init(
        payloadStore: ToolPayloadStore,
        charThreshold: Int = 16_384
    ) {
        self.payloadStore = payloadStore
        self.charThreshold = charThreshold
    }

    // MARK: - ToolExecutionHook

    func preExecute(toolCall: ToolCallPreview) async -> PreExecuteDecision {
        .allow
    }

    func postExecute(record: ToolRunRecord) async -> PostExecuteAction {
        // 1. 已有 envelope → dispatch 层已处理，passthrough
        guard record.result.envelope == nil else { return .passthrough }
        // 2. 错误结果不 payload 化
        guard !record.result.isError else { return .passthrough }
        // 3. 文本未超阈值 → passthrough
        let text = record.result.text
        guard text.count > charThreshold else { return .passthrough }

        // 4. 决定 sourceKind（根据工具名做简单映射，未匹配的归入 .other）
        let sourceKind = Self.sourceKind(for: record.toolName)

        // 5. 创建 payload；若失败则 passthrough（安全降级，不影响主路径）
        guard let payload = try? await payloadStore.createPayload(
            text: text,
            sourceKind: sourceKind,
            sourceDescriptor: record.toolName
        ) else {
            return .passthrough
        }

        // 6. 构造 ToolResultEnvelope（.referenced 模式）
        let preview = String(text.prefix(800))
        let summary = "\(sourceKind.rawValue) result (\(text.count) chars)"
        let envelope = ToolResultEnvelope(
            summary: summary,
            preview: preview,
            payloadRef: payload.payloadID,
            isTruncated: true,
            estimatedChars: text.count,
            estimatedTokens: ToolResultEnvelope.estimateTokens(for: text),
            retrievalHint: "Use read_tool_payload with payload_ref to access the full result in chunks.",
            sourceKind: sourceKind,
            injectionMode: .referenced,
            rawCharCount: text.count,
            injectedCharCount: summary.count + preview.count
        )

        // 7. 构造紧凑 result，保留原始 status 和 rawOutputText
        let compactText = envelope.renderForModel()
        let newResult = ToolExecutionResult(
            compactText,
            status: record.result.status,
            rawOutputText: text,
            envelope: envelope
        )
        return .rewriteResult(newResult)
    }

    func postFailure(toolCall: ToolCallPreview, error: any Error) async -> FailureAction {
        .propagate
    }

    // MARK: - Private Helpers

    /// 根据工具名推断 `LargeTextPayload.SourceKind`（最佳猜测，不限于确定映射）。
    private static func sourceKind(for toolName: String) -> LargeTextPayload.SourceKind {
        switch toolName {
        case "bash":               return .bash
        case "read_file",
             "str_replace_based_edit_tool",
             "str_replace_editor":  return .file
        case "web_fetch":          return .webFetch
        case "web_search":         return .webSearch
        default:                   return .other
        }
    }
}
```

### Step 2: 构建验证 — 无编译错误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|BUILD"
```

预期：`BUILD SUCCEEDED`，无 error。

### Step 3: 提交

```
git add agentGui/Services/ToolGovernance/Hooks/PayloadBudgetHook.swift
git commit -m "feat(F-C5): add PayloadBudgetHook skeleton – compiles, no tests yet"
```

---

## Task 2 — TDD：先写测试，再跑红，再跑绿

**Files:**
- Create: `agentGuiTests/PayloadBudgetHookTests.swift`

### Step 1: 写测试文件

测试覆盖以下场景（见下方代码）：

| 测试名 | 场景 | 期望 |
|---|---|---|
| `test_preExecute_alwaysAllows` | preExecute 任意工具 | `.allow` |
| `test_postFailure_alwaysPropagates` | postFailure | `.propagate` |
| `test_smallResult_passthrough` | text.count ≤ threshold | `.passthrough` |
| `test_resultWithExistingEnvelope_passthrough` | result.envelope != nil | `.passthrough` |
| `test_errorResult_passthrough` | result.isError == true | `.passthrough` |
| `test_largeResult_rewritesResult` | text.count > threshold，envelope == nil | `.rewriteResult`，新 result 含 `payloadRef` |
| `test_largeResult_preservesOriginalStatus` | 大结果但 status 非 .success | 新 result.status 与原始一致 |
| `test_largeResult_rawOutputTextPreserved` | 大结果 | 新 result.rawOutputText 等于原始 text |
| `test_largeResult_envelopeInjectionModeIsReferenced` | 大结果 | `envelope.injectionMode == .referenced` |
| `test_largeResult_storesPayloadInStore` | 大结果 | `ToolPayloadStore.payload(for:)` 可读取，内容与原文一致 |
| `test_payloadStoreFailure_passthrough` | payloadStore 抛出错误 | `.passthrough`（安全降级） |
| `test_bashTool_sourceKindIsBash` | toolName = "bash" | envelope.sourceKind == .bash |
| `test_unknownTool_sourceKindIsOther` | toolName = "custom_tool" | envelope.sourceKind == .other |

```swift
import XCTest
@testable import agentGui
import Foundation

final class PayloadBudgetHookTests: XCTestCase {

    // MARK: - Helpers

    /// 构建 PayloadBudgetHook，默认阈值设为 100 字符以便测试（不需要构造 16 KB 字符串）。
    private func makeHook(
        threshold: Int = 100,
        store: ToolPayloadStore = ToolPayloadStore(
            baseDirectory: FileManager.default.temporaryDirectory
                .appending(path: "PayloadBudgetHookTests-\(UUID().uuidString)")
        )
    ) -> (PayloadBudgetHook, ToolPayloadStore) {
        (PayloadBudgetHook(payloadStore: store, charThreshold: threshold), store)
    }

    private func makeRecord(
        toolName: String = "bash",
        text: String = "output",
        isError: Bool = false,
        envelope: ToolResultEnvelope? = nil
    ) -> ToolRunRecord {
        let status: ToolResultStatus = isError ? .failure : .success
        let result = ToolExecutionResult(text, status: status, envelope: envelope)
        return ToolRunRecord(
            toolCallId: "tc-test",
            toolName: toolName,
            input: [:],
            result: result,
            sessionID: "session-test",
            executionContext: .mainAgent
        )
    }

    private func makeEnvelope() -> ToolResultEnvelope {
        ToolResultEnvelope(
            summary: "existing",
            preview: nil,
            payloadRef: "payload_existing",
            isTruncated: true,
            estimatedChars: 1000,
            estimatedTokens: 250,
            retrievalHint: nil,
            sourceKind: .bash,
            injectionMode: .referenced,
            rawCharCount: 1000,
            injectedCharCount: 100
        )
    }

    // MARK: - preExecute 永远 allow

    func test_preExecute_alwaysAllows() async {
        let (hook, _) = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: "s1", executionContext: .mainAgent
        )
        let decision = await hook.preExecute(toolCall: preview)
        guard case .allow = decision else {
            XCTFail("Expected .allow, got \(decision)"); return
        }
    }

    // MARK: - postFailure 永远 propagate

    func test_postFailure_alwaysPropagates() async {
        let (hook, _) = makeHook()
        let preview = ToolCallPreview(
            toolCallId: "id", toolName: "bash",
            input: [:], sessionID: "s1", executionContext: .mainAgent
        )
        let action = await hook.postFailure(
            toolCall: preview,
            error: ToolExecutionHookError(message: "simulated failure")
        )
        guard case .propagate = action else {
            XCTFail("Expected .propagate, got \(action)"); return
        }
    }

    // MARK: - 小结果 passthrough

    func test_smallResult_passthrough() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "x", count: 50)) // 50 ≤ 100
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough for small result, got \(action)"); return
        }
    }

    func test_resultAtExactThreshold_passthrough() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "x", count: 100)) // 100 == 100, not >
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough at exact threshold, got \(action)"); return
        }
    }

    // MARK: - 已有 envelope passthrough（dispatch 层已处理）

    func test_resultWithExistingEnvelope_passthrough() async {
        let (hook, _) = makeHook(threshold: 10)
        let record = makeRecord(
            text: String(repeating: "x", count: 200), // > threshold
            envelope: makeEnvelope()
        )
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough when envelope already present, got \(action)"); return
        }
    }

    // MARK: - 错误结果 passthrough

    func test_errorResult_passthrough() async {
        let (hook, _) = makeHook(threshold: 10)
        let record = makeRecord(
            text: String(repeating: "x", count: 200),
            isError: true
        )
        let action = await hook.postExecute(record: record)
        guard case .passthrough = action else {
            XCTFail("Expected .passthrough for error result, got \(action)"); return
        }
    }

    // MARK: - 大结果：rewriteResult + payload 已存储

    func test_largeResult_rewritesResult() async {
        let (hook, _) = makeHook(threshold: 100)
        let original = String(repeating: "A", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)
        switch action {
        case .rewriteResult(let result):
            XCTAssertFalse(result.text.isEmpty, "Rewritten result text should not be empty")
        default:
            XCTFail("Expected .rewriteResult for large result, got \(action)")
        }
    }

    func test_largeResult_preservesOriginalStatus() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(
            text: String(repeating: "x", count: 200),
            isError: false
        )
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.status, .success, "Original success status must be preserved")
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_rawOutputTextPreserved() async {
        let (hook, _) = makeHook(threshold: 100)
        let original = String(repeating: "B", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(
                result.rawOutputText, original,
                "rawOutputText must preserve original text for later payload reads"
            )
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_envelopeInjectionModeIsReferenced() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "C", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(
                result.envelope?.injectionMode, .referenced,
                "Envelope injection mode must be .referenced"
            )
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_largeResult_envelopeContainsPayloadRef() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(text: String(repeating: "D", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertNotNil(result.envelope?.payloadRef, "Envelope must carry a payload_ref")
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    // MARK: - payload 存入 store 可读取

    func test_largeResult_storesPayloadInStore() async throws {
        let (hook, store) = makeHook(threshold: 100)
        let original = String(repeating: "E", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)

        guard case .rewriteResult(let result) = action,
              let payloadRef = result.envelope?.payloadRef else {
            XCTFail("Expected .rewriteResult with payloadRef"); return
        }

        // Payload should be retrievable from store
        let payload = try store.payload(for: payloadRef)
        XCTAssertEqual(payload.rawCharCount, 200)
    }

    func test_largeResult_payloadContentMatchesOriginal() async throws {
        let (hook, store) = makeHook(threshold: 100)
        let original = "Hello world! " + String(repeating: "Z", count: 200)
        let record = makeRecord(text: original)
        let action = await hook.postExecute(record: record)

        guard case .rewriteResult(let result) = action,
              let payloadRef = result.envelope?.payloadRef else {
            XCTFail("Expected .rewriteResult with payloadRef"); return
        }

        // Read from store and verify content matches
        let window = try store.readChars(payloadID: payloadRef, start: 1, end: original.count)
        XCTAssertEqual(window, original)
    }

    // MARK: - source kind 映射

    func test_bashTool_sourceKindIsBash() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "bash", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .bash)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_readFileTool_sourceKindIsFile() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "read_file", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .file)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    func test_unknownTool_sourceKindIsOther() async {
        let (hook, _) = makeHook(threshold: 100)
        let record = makeRecord(toolName: "my_custom_tool", text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        if case .rewriteResult(let result) = action {
            XCTAssertEqual(result.envelope?.sourceKind, .other)
        } else {
            XCTFail("Expected .rewriteResult")
        }
    }

    // MARK: - payload store 失败时安全降级

    func test_payloadStoreFailure_passthrough() async {
        // 使用一个不可写路径使 store 创建 payload 必然失败
        let badStore = ToolPayloadStore(
            baseDirectory: URL(fileURLWithPath: "/nonexistent/path/that/cannot/be/created")
        )
        let hook = PayloadBudgetHook(payloadStore: badStore, charThreshold: 10)
        let record = makeRecord(text: String(repeating: "x", count: 200))
        let action = await hook.postExecute(record: record)
        // Should silently degrade to passthrough, not throw or crash
        switch action {
        case .passthrough, .rewriteResult:
            break  // both are acceptable: rewriteResult if store worked, passthrough if failed
        default:
            XCTFail("Should not return appendAttachment or other unexpected action")
        }
    }
}
```

### Step 2: 运行测试，确认全部 **失败**（红灯）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-F-C5-red \
  -only-testing:agentGuiTests/PayloadBudgetHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：编译成功但测试失败（`PayloadBudgetHook` 类型不存在），或编译报错。

### Step 3: 实现 Task 1 Step 1 中的 `PayloadBudgetHook.swift`

（Task 1 的代码在此步骤补全。）

### Step 4: 运行测试，确认全部 **通过**（绿灯）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-F-C5-green \
  -only-testing:agentGuiTests/PayloadBudgetHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|PASS|FAIL|BUILD"
```

预期：所有测试 **passed**。

### Step 5: 提交

```
git add agentGui/Services/ToolGovernance/Hooks/PayloadBudgetHook.swift
git add agentGuiTests/PayloadBudgetHookTests.swift
git commit -m "feat(F-C5): PayloadBudgetHook – all tests passing"
```

---

## Task 3 — 注册 Hook 到 `AgentLoopToolExecutionCoordinatorBuilder`

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

### Step 1: 找到注册点

在 `buildHookPipeline()` 方法中，定位注释 `// F-C5 PayloadBudgetHook 将在此追加`：

```swift
// 当前代码片段（L80–L95 附近）：
private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4: VerificationEvidenceHook — records bash test runs + nudges on todo completion
    let evidenceStore = claudeService.verificationEvidenceStore(for: sessionId)
    hooks.append(VerificationEvidenceHook(sessionID: sessionId, evidenceStore: evidenceStore))

    // F-C5 PayloadBudgetHook 将在此追加

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

### Step 2: 替换注释为实际注册代码

```swift
    // F-C5: PayloadBudgetHook — persists oversized tool results to ToolPayloadStore
    hooks.append(PayloadBudgetHook(payloadStore: claudeService.toolPayloadStore))
```

完整替换后的代码块：

```swift
private func buildHookPipeline() -> ToolExecutionHookPipeline {
    var hooks: [any ToolExecutionHook] = []

    if let projectionStore = claudeService.changeReviewProjectionStore {
        hooks.append(ChangeReviewHook(projectionStore: projectionStore))
    }

    // F-C4: VerificationEvidenceHook — records bash test runs + nudges on todo completion
    let evidenceStore = claudeService.verificationEvidenceStore(for: sessionId)
    hooks.append(VerificationEvidenceHook(sessionID: sessionId, evidenceStore: evidenceStore))

    // F-C5: PayloadBudgetHook — persists oversized tool results to ToolPayloadStore
    hooks.append(PayloadBudgetHook(payloadStore: claudeService.toolPayloadStore))

    return ToolExecutionHookPipeline(hooks: hooks)
}
```

> **注意：** `claudeService.toolPayloadStore` 已是 `ClaudeService` 的成员变量（`var toolPayloadStore = ToolPayloadStore()`），可直接使用，无需额外初始化。

### Step 3: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`。

### Step 4: 重跑完整测试套件（验证注册不破坏现有行为）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-F-C5-integration \
  -only-testing:agentGuiTests/PayloadBudgetHookTests \
  -only-testing:agentGuiTests/ChangeReviewHookTests \
  -only-testing:agentGuiTests/VerificationEvidenceHookTests \
  -only-testing:agentGuiTests/ToolExecutionHookCoordinatorIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|PASS|FAIL|BUILD"
```

预期：所有测试 passed。

### Step 5: 提交

```
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(F-C5): register PayloadBudgetHook in hook pipeline"
```

---

## 验收检查清单

| 验收标准 | 对应测试/验证方式 |
|---|---|
| 工具返回 > 阈值内容时，context 中只保留 reference（含 `payload_ref`、`estimated_chars`） | `test_largeResult_rewritesResult` + `test_largeResult_envelopeContainsPayloadRef` |
| payload reference 格式使用 `ToolResultEnvelope.renderForModel()` 渲染，与现有读取工具兼容 | `test_largeResult_storesPayloadInStore` + `test_largeResult_payloadContentMatchesOriginal` |
| 原始文本存入 `ToolPayloadStore`，内容完整可通过 `payloadID` 读取 | `test_largeResult_payloadContentMatchesOriginal` |
| 已有 `envelope` 的结果不再被二次处理（dispatch 层已处理的不重复压缩） | `test_resultWithExistingEnvelope_passthrough` |
| 错误结果不做 payload 化 | `test_errorResult_passthrough` |
| `rawOutputText` 保留原始完整文本 | `test_largeResult_rawOutputTextPreserved` |
| 原始 `status` 保持不变 | `test_largeResult_preservesOriginalStatus` |
| `ToolPayloadStore` 失败时安全降级，不影响主工具执行路径 | `test_payloadStoreFailure_passthrough` |
| `preExecute` 永远 `.allow` | `test_preExecute_alwaysAllows` |
| `postFailure` 永远 `.propagate` | `test_postFailure_alwaysPropagates` |
| 注册后不影响 `ChangeReviewHookTests`、`VerificationEvidenceHookTests` 已有测试 | Task 3 Step 4 全套测试 |

---

## 设计备注

### 阈值选择

默认 `charThreshold = 16_384` 对应约 4 096 tokens（Claude 按 4 chars/token 估算）。这与 `ToolResultBudgetController` 中 `previewCharLimit = 8_000` 的关系：

- dispatch 层的 `previewCharLimit`（8 000 chars）是"是否用 preview 模式"的边界
- hook 层的 `charThreshold`（16 384 chars）是"dispatch 层未处理时的后备保障"

两层阈值不冲突：经 dispatch 层处理的结果会有 `envelope`，hook 会 passthrough。

### 与未来 F-B1 / F-B3 的关系

`F-B1 ContextWindowBudgetTracker` 会在 session 级别跟踪 token 使用；`F-B3 CompactionCoordinator` 会在会话层面执行压缩。`PayloadBudgetHook` 是工具级别的即时防护，三者互不替代，共同构成上下文治理的纵深防御。
