# Large Text Tool Budget Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a unified large-text budget governance layer so file reads, bash output, and web content stop flowing back into the model as raw full-text strings and instead use summary, preview, and resumable payload references.

**Architecture:** Introduce a shared large-text contract made of `ToolResultEnvelope`, `LargeTextPayload`, and a `ToolPayloadStore`, then enforce budget-aware result shaping in the tool execution path before tool results are appended into the agent loop. Adapt the text editor, bash, and web tools to emit the same envelope contract, add a unified `read_tool_payload` continuation tool, and persist enough metadata onto `ToolCall` for UI inspection and observability.

**Tech Stack:** Swift 6, Swift Testing, SwiftData, SwiftAnthropic, Foundation file I/O, existing `ClaudeService`, `ToolRegistry`, `BashSession`, and SwiftUI tool-call detail views.

---

## 1. 实施原则

- 不做“每个工具各加一点截断逻辑”的补丁式修复，优先把统一 contract、统一预算门控、统一续读协议立起来。
- 先锁测试，再替换主链路，避免把 `ToolExecutionResult.text` 直接升级成复杂结构后失去回归保护。
- 先做 P0 主链路：统一 envelope、payload 存储、统一读取入口、text/bash/web 三类工具接入；结构化导航增强放在后续 task。
- 对 UI 只做支持新元数据和新摘要结构的最小改动，不在本期重做整个 Tool Call 展示系统。
- 不迁移历史 `ToolCall` 数据。新字段默认可空，旧记录继续按旧展示逻辑工作。
- 优先使用临时目录文件作为 payload 真正载体，SwiftData 只保存轻量审计元数据或通过 `ToolCall` 挂接引用，避免把大正文再次塞回模型层或数据库层。

## 2. 范围边界

### 本期必须完成

- 统一的 `ToolResultEnvelope`
- 统一的 `LargeTextPayload` / `payload_ref`
- 统一的 `read_tool_payload` 工具
- 统一预算分级：`inline` / `preview` / `referenced`
- 文本工具、bash、web fetch、web search 接入统一分级输出
- `ToolCall` / UI / observability 能看到 payload 是否创建、原始大小、注入大小、读取次数

### 本期不做

- 向量检索、RAG、embedding、语义检索
- 非文本载荷，例如图片、音频、视频
- 历史 `ToolCall` 数据迁移
- 真正语义级 chunking 引擎；第一版以字符、行、段落、简单 section 为主

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LargeTextPayload.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolResultEnvelope.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolPayloadStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolResultBudgetController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolPayloadRead.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolResultEnvelopeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPayloadStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolResultBudgetControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPayloadReadToolTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextTextEditorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextBashBudgetTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextWebToolBudgetTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift:12-131`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift:24-184`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift:27-70`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift:12-138`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolExecutionResult.swift:10-106`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift:9-136`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift:736-895`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+TextEditorTool.swift:15-148`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift:8-260`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift:42-94`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WebTools.swift:83-326`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift:14-228`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift:3-236`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift:6-49`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift:6-41`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift:6-31`

## 4. 关键设计决策

### 4.1 `ToolExecutionResult` 继续存在，但不再只有裸文本

不要把所有调用点一次性改成直接操作 JSON `String`。保留 `ToolExecutionResult` 作为执行层统一返回对象，但新增 envelope 语义字段，例如：

```swift
struct ToolResultEnvelope: Codable, Equatable, Sendable {
    enum InjectionMode: String, Codable, Sendable {
        case inline
        case preview
        case referenced
    }

    let summary: String
    let preview: String?
    let payloadRef: String?
    let isTruncated: Bool
    let estimatedChars: Int
    let estimatedTokens: Int
    let retrievalHint: String?
    let sourceKind: SourceKind
    let injectionMode: InjectionMode
    let rawCharCount: Int
    let injectedCharCount: Int
}
```

`ToolExecutionResult.text` 在 V1 中应改为“发送给模型的最终文本表示”，但其来源不再是工具 executor 自己拼的大字符串，而是 `ToolResultEnvelope.renderForModel()` 的结果。这样可以把改动集中在 dispatch 和 loop 层，不必一次性推翻所有 hook 和 UI 代码。

### 4.2 `payload_ref` 采用统一工具，而不是 `payload://` 假路径

V1 推荐新增 `read_tool_payload` 工具，不把它伪装成文件路径。原因：

- 它和文本文件读取不是同一个语义层
- 需要支持字符区间、行区间、chunk、摘要、目录、命中块等多种读取方式
- 未来 bash/web/search 都要共用，单独工具更容易在 prompt 中教学与约束

工具输入建议：

```swift
{
  "payload_ref": "payload_...",
  "read_mode": "summary|preview|chars|lines|chunk|head|tail",
  "start": 1,
  "end": 200,
  "cursor": "chunk:3",
  "max_chars": 4000
}
```

### 4.3 payload 真正存储位置选“私有临时目录 + 轻量元数据”

V1 不把大正文落到 SwiftData。建议：

- 大正文保存到 app 私有临时目录，例如 Application Support 或 Caches 下的 `tool_payloads/`
- `LargeTextPayload` 作为轻量元数据模型，记录 `payloadID`、来源、大小、创建时间、TTL、索引信息、文件 URL
- `ToolCall` 只存引用和摘要级统计，不存全文副本

这样最贴合需求里的“脱离上下文保存原文”目标，也能避免 `ToolCall.terminalOutput` 继续成为第二份大文本副本。

### 4.4 预算门控在 tool executor 之后、agent loop 注入之前统一执行

不要在 `executeTextEditorTool`、`executeBashTool`、`executeWebFetchTool` 各自写死阈值。每个工具先尽量返回“原始文本 + source metadata”，随后交给统一 `ToolResultBudgetController` 决定：

- 是否可 inline
- 是否降级为 preview
- 是否必须 referenced
- 是否需要创建 payload

第一版预算输入建议至少包含：

- 本轮当前已累计注入字符数
- 单工具结果原始字符数
- 工具类型
- 当前模型最大输出与思考预算的保留余量

## 5. 任务拆解

### Task 1: 建立大文本 contract 与 payload 存储骨架

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/LargeTextPayload.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolResultEnvelope.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolPayloadStore.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolResultEnvelopeTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPayloadStoreTests.swift`

**Step 1: Write the failing tests**

新增 `ToolResultEnvelopeTests.swift`，锁定以下行为：

- `inline` 模式下 `payloadRef == nil`
- `referenced` 模式下必须有 `payloadRef`
- `renderForModel()` 输出必须包含 `summary`、`preview`、`payload_ref`、`retrieval_hint`
- `estimatedTokens` 由统一估算函数生成，不在各工具内散落计算

新增 `ToolPayloadStoreTests.swift`，锁定以下行为：

- 可将一段大文本写入临时目录并返回稳定 `payloadID`
- 可按字符区间和行区间读取
- 超出范围返回 `invalid_range`
- 过期 payload 返回 `payload_expired`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ToolResultEnvelopeTests {

    @Test func referencedEnvelopeRequiresPayloadRef() throws {
        let envelope = ToolResultEnvelope(
            summary: "large output",
            preview: "head...",
            payloadRef: "payload_123",
            isTruncated: true,
            estimatedChars: 12000,
            estimatedTokens: 3000,
            retrievalHint: "Use read_tool_payload with chunk mode",
            sourceKind: .bash,
            injectionMode: .referenced,
            rawCharCount: 12000,
            injectedCharCount: 400
        )

        #expect(envelope.payloadRef == "payload_123")
        #expect(envelope.renderForModel().contains("payload_ref: payload_123"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolResultEnvelopeTests \
  -only-testing:agentGuiTests/ToolPayloadStoreTests
```

Expected: FAIL，因为 envelope、payload store、range read API 还不存在。

**Step 3: Write minimal implementation**

在 `LargeTextPayload.swift` 中实现最小模型：

```swift
struct LargeTextPayload: Codable, Equatable, Sendable {
    enum SourceKind: String, Codable, Sendable {
        case file
        case bash
        case webFetch
        case webSearch
        case other
    }

    let payloadID: String
    let sourceKind: SourceKind
    let sourceDescriptor: String
    let fileURL: URL
    let createdAt: Date
    let expiresAt: Date
    let rawCharCount: Int
    let lineCount: Int?
}
```

在 `ToolPayloadStore.swift` 中实现：

- `createPayload(text:sourceKind:sourceDescriptor:ttl:)`
- `readChars(payloadID:start:end:)`
- `readLines(payloadID:start:end:)`
- `readChunk(payloadID:cursor:maxChars:)`
- `deleteExpiredPayloads()`

第一版 chunk 可以按固定字符窗口实现，后续再增强 section / paragraph 导航。

**Step 4: Run test to verify it passes**

执行同一组 `xcodebuild` 命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/LargeTextPayload.swift agentGui/Models/ToolResultEnvelope.swift agentGui/Services/ToolPayloadStore.swift agentGuiTests/ToolResultEnvelopeTests.swift agentGuiTests/ToolPayloadStoreTests.swift
git commit -m "feat: add large text payload contract and store"
```

### Task 2: 建立统一预算门控，并让 `ToolExecutionResult` 支持 envelope

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolResultBudgetController.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolResultBudgetControllerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolExecutionResult.swift:10-106`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift:736-895`

**Step 1: Write the failing tests**

新增 `ToolResultBudgetControllerTests.swift`，覆盖：

- 小结果进入 `inline`
- 中结果进入 `preview`
- 大结果进入 `referenced`
- 当本轮已累计注入字符数偏高时，即便中等结果也降级为 `referenced`
- `injectedCharCount` 必须小于 `rawCharCount` 才能判定为预算节省

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ToolResultBudgetControllerTests {

    @Test func oversizedResultFallsBackToReferencedMode() throws {
        let controller = ToolResultBudgetController()
        let decision = controller.decide(
            rawText: String(repeating: "A", count: 20000),
            sourceKind: .bash,
            roundInjectedChars: 1000,
            reservedResponseTokens: 4096
        )

        #expect(decision.mode == .referenced)
        #expect(decision.preview.count < 2000)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolResultBudgetControllerTests
```

Expected: FAIL，因为预算控制器和 envelope 接线还不存在。

**Step 3: Write minimal implementation**

实现 `ToolResultBudgetController`：

```swift
struct ToolBudgetDecision: Sendable {
    let mode: ToolResultEnvelope.InjectionMode
    let summary: String
    let preview: String?
    let shouldPersistPayload: Bool
    let retrievalHint: String
}
```

建议第一版阈值：

- `inline`: 原始结果 < 2_000 chars 且本轮累计注入 < 6_000 chars
- `preview`: 原始结果 < 8_000 chars 且本轮累计注入 < 12_000 chars
- `referenced`: 其余情况

同时改造 `ToolExecutionResult`，新增：

- `envelope: ToolResultEnvelope?`
- `rawOutputText: String?`
- 保留 `text` 作为最终注入模型的渲染文本

**Step 4: Wire the agent loop**

在 `ClaudeService+AgenticLoop.swift` 的工具执行收尾路径中：

- 维护本轮已注入字符统计
- 对每次工具原始输出调用 budget controller
- 需要 referenced 时调用 `ToolPayloadStore` 生成 payload
- `toolResultObjects.append(.toolResult(...))` 使用 envelope 渲染文本，而不是工具 executor 原始全文
- `emitHook(.didExecuteTool, ...)` 同时发出 `rawOutputLength` 和 `injectedOutputLength`

**Step 5: Run focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolResultBudgetControllerTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Services/ToolResultBudgetController.swift agentGui/Services/ClaudeService+ToolExecutionResult.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/ToolResultBudgetControllerTests.swift agentGuiTests/AgentLoopToolAuditHookTests.swift
git commit -m "feat: add budget-aware tool result shaping"
```

### Task 3: 新增统一 `read_tool_payload` 工具并接入注册与分发

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolPayloadRead.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPayloadReadToolTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift:24-184`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift:27-70`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift:12-138`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift:9-136`

**Step 1: Write the failing tests**

新增 `ToolPayloadReadToolTests.swift`，覆盖：

- 注册中心暴露 `read_tool_payload`
- 可按 `read_mode = lines` 读取指定行区间
- 返回结构中必须包含 `content`、`has_more`、`next_cursor`、`range_summary`
- 不存在的 payload 返回 `payload_not_found`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolPayloadReadToolTests \
  -only-testing:agentGuiTests/ToolRegistryTests
```

Expected: FAIL，因为工具定义、dispatcher 分支、读取 executor 还不存在。

**Step 3: Write minimal implementation**

在 `ToolRegistry.swift` 新增定义：

```swift
ToolDefinition(
    id: "read_tool_payload",
    displayName: "Read Tool Payload",
    category: .system,
    schemaVersion: 1,
    supportedContexts: [.mainAgent, .subagent, .workflowWorker],
    executorKey: "builtin.readToolPayload",
    ...
)
```

在 `ClaudeService+ToolPayloadRead.swift` 实现统一读取入口，返回内容示例：

```text
payload_ref: payload_123
range_summary: lines 201-260 of 920
chunk_index: 4
chunk_count: 16
has_more: true
next_cursor: lines:261-320

<content>
...
```

在 `ClaudeService+ToolCallRecord.swift` 中为该工具增加合理 title，例如“读取载荷 payload_123”。

**Step 4: Run test to verify it passes**

执行同一组 `xcodebuild` 命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolPayloadRead.swift agentGui/Services/ToolRegistry.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGuiTests/ToolPayloadReadToolTests.swift agentGuiTests/ToolRegistryTests.swift
git commit -m "feat: add unified tool payload reader"
```

### Task 4: 改造文本工具，让大文件默认走摘要 + 建议区间 + payload

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextTextEditorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+TextEditorTool.swift:15-148`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift:12-138`

**Step 1: Write the failing tests**

新增 `LargeTextTextEditorTests.swift`，覆盖：

- 小文件 `view` 继续 inline 返回完整内容
- 大文件 `view` 且未带 `view_range` 时，返回摘要、总行数、建议区间，不直接返回全文
- 大文件 `view` 且指定 `view_range` 时，只返回该区间，不创建额外 payload
- 读取结果中应包含“若需查看更多，调用 `read_tool_payload`”的 retrieval hint

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct LargeTextTextEditorTests {

    @Test func largeViewWithoutRangeReturnsNavigationInsteadOfWholeFile() async throws {
        let content = (1...1200).map { "line \($0)" }.joined(separator: "\n")
        let output = ClaudeService.renderTextEditorViewForTests(content: content, viewRange: nil)

        #expect(output.contains("1\tline 1"))
        #expect(output.contains("1200\tline 1200"))
    }
}
```

这里先让测试失败，随后把测试调整为真正验证 envelope 级行为，而不是旧 `renderTextEditorViewForTests` 的全文模式。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LargeTextTextEditorTests
```

Expected: FAIL，因为当前 `view` 默认整文件回填。

**Step 3: Write minimal implementation**

在 `ClaudeService+TextEditorTool.swift` 中拆出两个层次：

- 原始读取层：返回全文、总行数、建议区间
- 预算整形层：由 dispatch/loop 将其包装为 envelope

对于大文件且未指定 `view_range`：

- 生成 `summary`: 文件总行数、前后预览、建议区间
- 创建 `payload_ref`
- `preview` 只保留首尾小片段，不再把所有内容拼回模型

**Step 4: Run focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LargeTextTextEditorTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+TextEditorTool.swift agentGuiTests/LargeTextTextEditorTests.swift
git commit -m "feat: budget large text editor reads"
```

### Task 5: 改造 bash 工具与 `BashSession`，让长输出默认走 payload

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextBashBudgetTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift:8-260`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift:42-94`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift:736-895`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift:14-228`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift:3-236`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift:6-41`

**Step 1: Write the failing tests**

新增 `LargeTextBashBudgetTests.swift`，覆盖：

- 前台命令输出过长时，注入模型的是摘要 + 尾部预览 + `payload_ref`
- 后台任务继续返回任务摘要，但后续读取不再依赖用户手写 `cat` 或 `tail`
- `ToolCall` 上会记录 `payloadRef`、原始字符数、注入字符数

同时扩展 `BashToolCallPresentationTests.swift`，断言 UI 会显示“后台任务”之外的新大载荷元数据摘要。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LargeTextBashBudgetTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: FAIL，因为 bash 目前直接返回 transcript 文本，`ToolCall` 也没有 payload 元数据。

**Step 3: Write minimal implementation**

在 `BashSession.swift` 中保持 UI 轮询缓冲仍可裁剪，但新增“原始 transcript 归档能力”，例如：

- foreground 完成后返回完整 transcript 给预算层处理
- background 启动后生成 log payload descriptor
- 提供读取最新尾部预览的 helper，避免 UI 失去当前可见摘要

在 `ClaudeService+BashTool.swift` 中返回可用于 envelope 的结构性摘要：

- exit code
- timeout / background / interactive 状态
- 错误摘要
- 尾部关键片段

**Step 4: Run focused tests**

执行同一组 `xcodebuild` 命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/BashSession.swift agentGui/Services/ClaudeService+BashTool.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/LargeTextBashBudgetTests.swift agentGuiTests/BashToolCallPresentationTests.swift
git commit -m "feat: route large bash output through payload references"
```

### Task 6: 改造 web_search / web_fetch，统一返回摘要与 payload

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LargeTextWebToolBudgetTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+WebTools.swift:83-326`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift:12-138`

**Step 1: Write the failing tests**

新增 `LargeTextWebToolBudgetTests.swift`，覆盖：

- `web_search` 默认只返回有限结果列表与 snippet，不聚合长正文
- `web_fetch` 对长网页只返回标题、域名、摘要、关键预览和 `payload_ref`
- 当 `max_chars` 足够小且结果短时，仍可 inline
- `web_fetch` 长正文时 `estimatedChars > injectedCharCount`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/LargeTextWebToolBudgetTests
```

Expected: FAIL，因为当前 web 工具仍以纯文本全文返回。

**Step 3: Write minimal implementation**

在 `ClaudeService+WebTools.swift` 中拆分为：

- `parseSearchResults(...) -> WebSearchRawResult`
- `extractTextFromHTML(...) -> WebFetchRawResult`

原始结果至少提供：

- 页面标题 / 查询词
- URL / 域名
- snippet / preview blocks
- cleaned full text

然后交给统一预算层决定是否创建 payload。`max_chars` 继续保留，但其意义变为“raw extraction 上限”而不是唯一注入门控手段。

**Step 4: Run focused tests**

执行同一组 `xcodebuild` 命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+WebTools.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGuiTests/LargeTextWebToolBudgetTests.swift
git commit -m "feat: apply payload budgeting to web tools"
```

### Task 7: 扩充 `ToolCall`、UI 详情页与可观测性字段

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift:12-131`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift:9-136`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift:14-228`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift:3-236`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift:6-31`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift:6-49`

**Step 1: Write the failing tests**

扩展 `ToolCallDetailPresentationTests.swift` 和 `AgentLoopToolAuditHookTests.swift`，断言新增字段会正确保留并展示：

- `payloadRef`
- `toolResultRawChars`
- `toolResultInjectedChars`
- `toolPayloadReadCount`
- `toolResultInjectionMode`

建议 `ToolCall` 新字段：

```swift
var toolPayloadRef: String?
var toolResultRawChars: Int?
var toolResultInjectedChars: Int?
var toolPayloadReadCount: Int?
var toolResultInjectionMode: String?
var toolPayloadLastReadRange: String?
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests
```

Expected: FAIL，因为模型、详情页和 hook 测试都还不知道 payload 元数据。

**Step 3: Write minimal implementation**

在 `ToolCallDetailContentView.swift` 中新增只读 section：

- 大载荷引用
- 原始大小
- 注入大小
- 预算节省估算
- 最近读取区间

在 `ToolCallRowPresentation.swift` 中把次级摘要优先显示为 envelope summary，而不是直接取 `terminalOutput` 首行。

**Step 4: Run focused tests**

执行同一组 `xcodebuild` 命令，预期 PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/ToolCallDetailPresentationTests.swift agentGuiTests/AgentLoopToolAuditHookTests.swift
git commit -m "feat: expose large text payload metadata in tool call UI"
```

### Task 8: 更新工具描述、系统提示词约束与回归验证

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift:24-184`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift:27-70`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift:43-260`

**Step 1: Write the failing tests**

如果当前没有 prompt contract 级测试，新增最小断言或扩展现有 tool schema 测试，确保以下文本存在：

- 面对大结果优先看 `summary` / `preview`
- 需要查看更多时调用 `read_tool_payload`
- 不要重复请求整段全文

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests
```

Expected: FAIL，如果 schema/description 还未更新。

**Step 3: Write minimal implementation**

更新 `ToolRegistry.swift` 中 `str_replace_based_edit_tool`、`bash`、`web_search`、`web_fetch`、`read_tool_payload` 的 description，使模型在协议层面学会：

- 大结果不是默认全文返回
- 优先摘要和预览
- 继续读取时使用统一 payload 工具

必要时在 `ClaudeService+AgenticLoop.swift` 的系统提示拼装路径中加入一段统一约束文本。

**Step 4: Run full focused regression**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests \
  -only-testing:agentGuiTests/ToolPayloadReadToolTests \
  -only-testing:agentGuiTests/LargeTextTextEditorTests \
  -only-testing:agentGuiTests/LargeTextBashBudgetTests \
  -only-testing:agentGuiTests/LargeTextWebToolBudgetTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: PASS。

**Step 5: Run smoke task**

Run workspace task: `Quality Smoke`

Expected: PASS，或至少没有引入与工具展示、agent loop、bash UI 相关的新回归。

**Step 6: Commit**

```bash
git add agentGui/Services/ToolRegistry.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+AgenticLoop.swift
git commit -m "feat: teach tools to use unified large text payload protocol"
```

## 6. 验收清单

- 超大文件 `view` 默认不再整文件注入模型，而是摘要、建议区间、`payload_ref`
- bash 长输出不再直接进入上下文全文，模型只看到摘要、尾部预览和 `payload_ref`
- web fetch 长网页不再整段回填，长正文走 payload
- text/bash/web 至少三类工具共用同一 envelope 渲染格式
- `read_tool_payload` 可稳定按 range / chunk 续读同一 payload
- `ToolCall` 详情可看到 `payload_ref`、原始大小、注入大小、读取次数
- loop hook / 观测元数据可回答“为什么这次结果被降级成 referenced”

## 7. 风险与回避策略

- 风险：`ToolExecutionResult` 结构调整会影响现有 hook 和 UI。回避：保留 `text` 作为最终渲染文本，先做兼容升级。
- 风险：payload 文件泄漏或长期堆积。回避：引入 TTL 和启动时清理。
- 风险：bash transcript 仍在多个层重复保存。回避：`ToolCall.terminalOutput` 只保留注入内容或 UI 预览，不存原始全文。
- 风险：测试难以稳定模拟超长输出。回避：使用纯字符串 fixture，不依赖真实 shell 大输出。

## 8. 建议实施顺序

1. 先完成 Task 1-3，把统一 contract、统一 store、统一读取入口立起来。
2. 再完成 Task 4-6，把 text/bash/web 三类工具逐个迁入预算协议。
3. 最后完成 Task 7-8，补齐 UI、observability 和 prompt 教学。

## 9. 完成定义

只有以下条件同时满足，才算本计划完成：

- 至少 text/bash/web fetch 三类工具已接入统一 payload 协议
- 新增 `read_tool_payload` 已上线且在工具描述中被明确教学
- 现有 agent loop 在工具结果注入前已经执行统一预算门控
- 关键测试与 `Quality Smoke` 通过
- Tool Call UI 能显示大文本预算治理的核心审计字段