# S-D4: Subagent `memory_write` Directory Isolation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让子代理调用 `memory_write` 工具时写入其专属记忆目录（`agent-memory/<agentType>/`），而非与主代理共享全局目录；同时在写入前增加凭证内容检测，防止 API Key 等敏感信息被误写入记忆文件。

**Architecture:** 将 `subagentMemoryDir: URL?` 注入到 `AgentLoopRuntime`，经 `runCoreAgentLoop` → `AgentLoopToolExecutionCoordinatorBuilder` 向下传播；builder 的 `executeTool` 闭包拦截 `memory_write` 调用并路由到子代理专属目录。主代理路径（`subagentMemoryDir == nil`）回退至现有全局路径，向后兼容。凭证检测以纯正则函数实现，置于 `executeFileMemoryWrite` 写入前。

**Tech Stack:** Swift 6, SwiftData, agentGui 现有 `AgentLoopRuntime` / `AgentLoopToolExecutionCoordinatorBuilder` / `ClaudeService+ToolDispatch` / `ClaudeService+Subagent`

**依赖 Feature 已完成：** S-D1（`AgentMemoryScope` + `AgentMemoryPathResolver`）、S-D2（`WorkflowRoleDefinition.memoryScope`）、S-D3（`composeSubagentMemorySection`，已在 `runSubagentLoop` 中计算 `agentMemDir`）

---

## 背景：当前状态 vs 目标状态

| 调用场景 | 当前行为 | 目标行为 |
|---|---|---|
| 主代理调用 `memory_write` | 写入 `~/.agentgui/memory/` ✓ | 不变 ✓ |
| 子代理（`memoryScope == nil`）调用 `memory_write` | 写入 `~/.agentgui/memory/` | 不变（fallback，向后兼容）|
| 子代理（`memoryScope != nil`）调用 `memory_write` | 写入 `~/.agentgui/memory/`（错误，污染主代理记忆）| 写入 `~/.agentgui/agent-memory/<agentType>/` |
| `memory_write` 内容含 API Key 等凭证 | 正常写入（安全隐患）| 拒绝写入，返回 Error |

---

## 涉及文件

| 文件 | 操作 |
|---|---|
| `agentGui/Models/AgentLoopRuntime.swift` | 修改：新增 `subagentMemoryDir: URL?` 字段 |
| `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift` | 修改：传播 `runtime.subagentMemoryDir` 到 builder |
| `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift` | 修改：新增 `subagentMemoryDir` 字段，拦截 `memory_write` |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | 修改：新增 `containsLikelyCredential`，在 `executeFileMemoryWrite` 写入前检测 |
| `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` | 修改：在构建 `AgentLoopRuntime` 时传入 `subagentMemoryDir` |
| `agentGuiTests/SubagentMemoryWriteIsolationTests.swift` | 新增：S-D4 验收测试 |
| `agentGuiTests/MemoryWriteCredentialGuardTests.swift` | 新增：凭证检测单元测试 |

---

## Task 1：新增凭证检测函数与 `executeFileMemoryWrite` 拦截

**文件：**
- 修改：`agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift`

凭证检测是纯逻辑，应最先实现，然后接入现有 `executeFileMemoryWrite(input:memoryDir:)` 写入前。

### Step 1: 在测试文件中写失败测试

**新建** `agentGuiTests/MemoryWriteCredentialGuardTests.swift`：

```swift
import XCTest
import SwiftAnthropic
@testable import agentGui

/// S-D4: memory_write 凭证防护测试
@MainActor
final class MemoryWriteCredentialGuardTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredGuardTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func buildInput(content: String, title: String = "Test") -> MessageResponse.Content.Input {
        ["content": .string(content), "title": .string(title)]
    }

    func test_credentialContent_anthropicKey_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "My key is sk-ant-api03-XXXXXXXXXXXX"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 sk-ant- 开头的内容应被拒绝: \(result)")
    }

    func test_credentialContent_bearerToken_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Authorization: Bearer ghp_XXXXXXXXXXXXXXXXXX"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 Bearer token 的内容应被拒绝: \(result)")
    }

    func test_credentialContent_apiKeyAssignment_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "api_key = 'supersecretvalue123'"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 api_key 赋值的内容应被拒绝: \(result)")
    }

    func test_normalContent_withWordApiKey_inNarrativeContext_isAllowed() async {
        // "API Key" 出现在正常叙述中，不含具体凭证值，应允许
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "Settings page requires the user to enter their API key in the text field."),
            memoryDir: tempDir
        )
        XCTAssertFalse(result.hasPrefix("Error:"), "普通叙述内容不应被误判为凭证: \(result)")
    }

    func test_normalContent_noCredential_isAllowed() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "ClaudeService.swift should not be edited directly."),
            memoryDir: tempDir
        )
        XCTAssertFalse(result.hasPrefix("Error:"), "普通内容不应被拒绝: \(result)")
    }

    func test_credentialContent_passwordAssignment_isRejected() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "password: hunter2"),
            memoryDir: tempDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"), "含 password 赋值的内容应被拒绝: \(result)")
    }
}
```

### Step 2: 运行测试，确认 FAIL

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemoryWriteCredentialGuardTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd4-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：凭证被拒绝的测试 FAIL（函数不存在），普通内容允许的测试也可能 FAIL。

### Step 3: 实现 `containsLikelyCredential` 并接入写入流程

在 `ClaudeService+ToolDispatch.swift` 的 `executeFileMemoryWrite(input:memoryDir:)` 中，在 `guard let content = ...` 之后，文件写入之前插入凭证检测。

**找到的位置（`executeFileMemoryWrite(input:memoryDir:)` 的开头）：**

```swift
// 当前代码（第 534 行附近）：
private func executeFileMemoryWrite(
    input: MessageResponse.Content.Input,
    memoryDir: URL
) async -> String {
    guard let content = input["content"]?.stringValue, !content.isEmpty else {
        return "Error: missing required parameter 'content'"
    }
    // ... 后续代码
```

**修改后：** 在 `guard let content` 之后，立即加入凭证检测：

```swift
private func executeFileMemoryWrite(
    input: MessageResponse.Content.Input,
    memoryDir: URL
) async -> String {
    guard let content = input["content"]?.stringValue, !content.isEmpty else {
        return "Error: missing required parameter 'content'"
    }

    // S-D4: 凭证防护 — 防止将 API Key 等敏感信息持久化到记忆文件
    if Self.containsLikelyCredential(content) {
        return "Error: memory content appears to contain credentials or secrets. " +
               "Do not store API keys, passwords, or tokens in memory."
    }

    // ... 其余代码不变
```

**同时在文件底部（`// MARK: - Memory Write`  section 内）新增：**

```swift
// MARK: - S-D4 Credential Guard

/// 检测 `content` 是否包含明显的凭证模式。
/// 仅检测高置信度的凭证前缀/赋值模式，避免误判正常叙述。
///
/// 对齐 Claude Code `secretScanner` 思路：使用正则匹配已知凭证前缀：
/// - `sk-ant-`：Anthropic API Key 前缀
/// - `Bearer `：HTTP Bearer token
/// - `api[_-]?key\s*[:=]`：API Key 赋值（区分大小写不敏感）
/// - `password\s*[:=]`：密码赋值
/// - `token\s*[:=]`：token 赋值
/// - `secret\s*[:=]`：secret 赋值
///
/// - Returns: `true` 表示检测到凭证，应拒绝写入。
nonisolated static func containsLikelyCredential(_ content: String) -> Bool {
    let patterns = [
        #"sk-ant-"#,                       // Anthropic API key prefix
        #"\bBearer\s+\S{10,}"#,            // HTTP Bearer token（值至少10字符）
        #"\bapi[_-]?key\s*[:=]\s*['\"]?\S{6,}"#,   // api_key = '...' / apikey:xxx
        #"\bpassword\s*[:=]\s*\S{4,}"#,    // password = xxx
        #"\btoken\s*[:=]\s*['\"]?\S{8,}"#, // token = '...'
        #"\bsecret\s*[:=]\s*['\"]?\S{6,}"#, // secret = '...'
    ]
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(content.startIndex..., in: content)
            if regex.firstMatch(in: content, range: range) != nil {
                return true
            }
        }
    }
    return false
}
```

### Step 4: 运行测试，确认 PASS

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemoryWriteCredentialGuardTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd4-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：全部 6 个测试 PASS。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift \
        agentGuiTests/MemoryWriteCredentialGuardTests.swift
git commit -m "feat(S-D4): add credential guard to memory_write before file write"
```

---

## Task 2：在 `AgentLoopRuntime` 添加 `subagentMemoryDir` 字段

**文件：**
- 修改：`agentGui/Models/AgentLoopRuntime.swift`

`AgentLoopRuntime` 是随 loop 流动的运行时上下文，是传播 subagent 专属记忆目录的最自然位置。

### Step 1: 写失败测试（编译失败即 FAIL）

在测试文件（Task 5 中正式创建的 `SubagentMemoryWriteIsolationTests.swift`）里先写一个编译探针，确认 `subagentMemoryDir` 不存在：

```swift
// 在 Task 5 的测试文件中先写这个 placeholder 以触发编译失败
// func test_placeholder_runtime_subagentMemoryDir_fieldExists() {
//     var runtime = AgentLoopRuntime(...)
//     _ = runtime.subagentMemoryDir  // 编译时证明字段存在
// }
```

> 此处直接执行修改即可，编译失败 = "失败的测试"。

### Step 2: 在 `AgentLoopRuntime.swift` 新增字段与 init 参数

找到文件中 `let onMessagesSnapshot` 一行之后，`init(` 之前，添加：

```swift
/// S-D4: 子代理专属记忆目录（由 runSubagentLoop 通过 AgentMemoryPathResolver 计算后注入）。
/// - `nil`：主代理 loop 或无 memoryScope 的子代理，memory_write 写入全局目录（向后兼容）。
/// - 非 nil：子代理 loop，memory_write 写入此目录（agent-memory/<agentType>/ 路径）。
let subagentMemoryDir: URL?
```

然后在 `init(` 参数列表的末尾添加：

```swift
subagentMemoryDir: URL? = nil
```

在 `init` 体中添加赋值：

```swift
self.subagentMemoryDir = subagentMemoryDir
```

**完整 init 签名变化（仅新增一个尾部默认参数）：**

```swift
init(
    settings: AppSettings,
    session: Session?,
    sessionId: String,
    modelContext: ModelContext,
    makeRound: @escaping (Int) -> AgentRound,
    parentMessage: Message?,
    streamProjectionTarget: AgentLoopStreamProjectionTarget,
    toolInterceptor: ((String, MessageResponse.Content.Input) async -> ToolExecutionResult?)?,
    remoteDeliveryHandle: (any RemoteTurnDeliveryHandle)? = nil,
    subagentProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil,
    onMessagesSnapshot: (@Sendable ([MessageParameter.Message]) -> Void)? = nil,
    subagentMemoryDir: URL? = nil   // S-D4: 新增，默认 nil 保持向后兼容
) {
    // ... 现有赋值
    self.subagentMemoryDir = subagentMemoryDir
}
```

> **向后兼容保证：** 所有现有 `AgentLoopRuntime(...)` 调用无需修改，因为新参数有默认值 `nil`。

### Step 3: 运行编译检查

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sd4-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`，无编译错误。

### Step 4: Commit

```bash
git add agentGui/Models/AgentLoopRuntime.swift
git commit -m "feat(S-D4): add subagentMemoryDir field to AgentLoopRuntime"
```

---

## Task 3：在 `AgentLoopToolExecutionCoordinatorBuilder` 拦截 `memory_write`

**文件：**
- 修改：`agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

这是路由逻辑的核心：当 builder 持有 `subagentMemoryDir` 时，`executeTool` 闭包拦截 `memory_write` 并调用子代理专属路径；否则直接透传给 `claudeService.executeTool()`。

### Step 1: 写失败测试

暂时跳过独立测试（builder 是 `@MainActor` + SwiftData 依赖型组件，集成测试在 Task 5 覆盖）。先直接修改。

### Step 2: 在 builder struct 中新增字段

在 `let session: Session?` 之后添加：

```swift
/// S-D4: 子代理专属记忆目录（nil = 主代理，使用全局路径）。
let subagentMemoryDir: URL?
```

**注意：** `AgentLoopToolExecutionCoordinatorBuilder` 没有显式 `init`，Swift 自动生成 memberwise init。新增字段会改变自动 init 签名——所有构造点都需要更新（Task 4 处理）。为了避免大规模改动，将新字段设置为有默认值的方式——但 Swift 对 struct memberwise init **不支持默认值**。

**替代方案（推荐）：** 添加显式 `init` 以保持向后兼容：

在 builder struct 中添加：

```swift
init(
    claudeService: ClaudeService,
    service: any AnthropicService,
    modelId: String,
    toolApprovalMode: ToolApprovalMode,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext,
    session: Session?,
    subagentMemoryDir: URL? = nil   // S-D4: 默认 nil
) {
    self.claudeService = claudeService
    self.service = service
    self.modelId = modelId
    self.toolApprovalMode = toolApprovalMode
    self.settings = settings
    self.sessionId = sessionId
    self.modelContext = modelContext
    self.session = session
    self.subagentMemoryDir = subagentMemoryDir
}
```

> 现有所有 `AgentLoopToolExecutionCoordinatorBuilder(claudeService:..., session:)` 调用不用修改。

### Step 3: 在 `build()` 的 `executeTool` 闭包中插入拦截逻辑

找到 `build()` 内部的：

```swift
executeTool: { name, input in
    await claudeService.executeTool(
        name: name,
        input: input,
        settings: settings,
        sessionId: sessionId,
        modelContext: modelContext
    )
},
```

替换为：

```swift
executeTool: { name, input in
    // S-D4: 子代理专属目录路由 — 当 subagentMemoryDir 已设置时，将 memory_write 定向到代理专属目录
    if name == "memory_write", let agentMemDir = subagentMemoryDir {
        return .detect(
            await claudeService.executeFileMemoryWriteForTests(input: input, memoryDir: agentMemDir),
            toolName: name
        )
    }
    return await claudeService.executeTool(
        name: name,
        input: input,
        settings: settings,
        sessionId: sessionId,
        modelContext: modelContext
    )
},
```

> **`executeFileMemoryWriteForTests`** 已在 `ClaudeService+ToolDispatch.swift` 中作为 `internal` 级可测 overload 存在，此处复用，不引入新 API。

### Step 4: 在闭包开头捕获 `subagentMemoryDir`

在 `build()` 方法开头（`let executor = SubagentBackgroundExecutor()` 之后），添加对 `subagentMemoryDir` 的本地捕获（避免闭包直接捕获 `self`）：

```swift
let capturedSubagentMemoryDir = subagentMemoryDir
```

然后在 `executeTool` 闭包中使用 `capturedSubagentMemoryDir` 替代 `subagentMemoryDir`。

### Step 5: 编译检查

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sd4-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 6: Commit

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(S-D4): intercept memory_write in coordinator builder for subagent dir routing"
```

---

## Task 4：在 `runCoreAgentLoop` 将 `runtime.subagentMemoryDir` 传入 builder

**文件：**
- 修改：`agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

### Step 1: 定位构造 builder 的代码

在 `runCoreAgentLoop` 中找到：

```swift
let toolExecutionCoordinator = AgentLoopToolExecutionCoordinatorBuilder(
    claudeService: self,
    service: request.service,
    modelId: request.modelId,
    toolApprovalMode: request.toolApprovalMode,
    settings: runtime.settings,
    sessionId: runtime.sessionId,
    modelContext: runtime.modelContext,
    session: runtime.session
).build()
```

### Step 2: 添加 `subagentMemoryDir` 参数

```swift
let toolExecutionCoordinator = AgentLoopToolExecutionCoordinatorBuilder(
    claudeService: self,
    service: request.service,
    modelId: request.modelId,
    toolApprovalMode: request.toolApprovalMode,
    settings: runtime.settings,
    sessionId: runtime.sessionId,
    modelContext: runtime.modelContext,
    session: runtime.session,
    subagentMemoryDir: runtime.subagentMemoryDir   // S-D4: 传播子代理专属记忆目录
).build()
```

### Step 3: 编译检查

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sd4-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 4: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "feat(S-D4): propagate runtime.subagentMemoryDir to tool coordinator builder"
```

---

## Task 5：在 `runSubagentLoop` 注入子代理专属记忆目录

**文件：**
- 修改：`agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

这是数据流的源头：当 `definition.memoryScope != nil` 时，在创建 `AgentLoopRuntime` 时传入已由 `composeSubagentMemorySection` 计算好的 `agentMemDir`。

### Step 1: 定位现有代码

在 `runSubagentLoop` 内，找到 `composeSubagentMemorySection` 调用处（S-D3 已实现）：

```swift
// S-D3 注入记忆
let workspaceRootURL: URL? = settings.workingDirectory.isEmpty
    ? nil
    : URL(fileURLWithPath: settings.workingDirectory)
let memorySectionText = ClaudeService.composeSubagentMemorySection(
    definition: definition,
    agentguiBaseDir: ConfigDirectoryManager.shared.agentGuiDir,
    workspaceRoot: workspaceRootURL
)
```

然后找到 `AgentLoopRuntime(...)` 构造处（S-D3 之后，`runCoreAgentLoop` 之前）：

```swift
let runtime = AgentLoopRuntime(
    settings: settings,
    session: nil,
    sessionId: sessionId,
    modelContext: modelContext,
    makeRound: { idx in
        let round = AgentRound(roundIndex: idx)
        round.subagentToolCall = toolCallRecord
        return round
    },
    parentMessage: nil,
    streamProjectionTarget: .none,
    toolInterceptor: nil,
    subagentProgressUpdate: onProgressUpdate,  // S-C3
    onMessagesSnapshot: summaryCallbacks.map { cb in  // S-C4
        { msgs in cb.onMessagesUpdated(msgs) }
    }
)
```

### Step 2: 在 `AgentLoopRuntime` 构建前计算 `subagentMemoryDirForRuntime`

在 `composeSubagentMemorySection` 调用之后，`AgentLoopRuntime(...)` 之前，添加：

```swift
// S-D4: 计算子代理专属记忆目录（用于 memory_write 路由）。
// 与 S-D3 的 composeSubagentMemorySection 使用相同的 resolver 和 scope，
// 但返回 URL 而非系统提示片段，供 AgentLoopRuntime 携带给工具执行器。
let subagentMemoryDirForRuntime: URL? = {
    guard let scope = definition.memoryScope,
          AgentMemoryPathResolver.sanitize(definition.name) != nil else {
        return nil
    }
    let resolver = AgentMemoryPathResolver(
        agentguiBaseDir: ConfigDirectoryManager.shared.agentGuiDir,
        workspaceRoot: workspaceRootURL
    )
    return resolver.memoryDir(agentType: definition.name, scope: scope)
}()
```

### Step 3: 将 `subagentMemoryDirForRuntime` 传入 `AgentLoopRuntime`

更新 `AgentLoopRuntime(...)` 构造：

```swift
let runtime = AgentLoopRuntime(
    settings: settings,
    session: nil,
    sessionId: sessionId,
    modelContext: modelContext,
    makeRound: { idx in
        let round = AgentRound(roundIndex: idx)
        round.subagentToolCall = toolCallRecord
        return round
    },
    parentMessage: nil,
    streamProjectionTarget: .none,
    toolInterceptor: nil,
    subagentProgressUpdate: onProgressUpdate,  // S-C3
    onMessagesSnapshot: summaryCallbacks.map { cb in  // S-C4
        { msgs in cb.onMessagesUpdated(msgs) }
    },
    subagentMemoryDir: subagentMemoryDirForRuntime  // S-D4
)
```

### Step 4: 编译检查

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sd4-task5 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

预期：`Build succeeded`。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(S-D4): inject subagentMemoryDir into AgentLoopRuntime in runSubagentLoop"
```

---

## Task 6：S-D4 验收测试

**文件：**
- 新建：`agentGuiTests/SubagentMemoryWriteIsolationTests.swift`

验收目标（来自设计文档）：
1. explore 子代理调用 `memory_write` 时，文件写入 `~/.agentgui/agent-memory/explore/`
2. 主代理调用 `memory_write` 仍写入 `~/.agentgui/memory/`
3. 含 `sk-ant-` 前缀的内容被拒绝写入

测试思路：通过 `executeFileMemoryWriteForTests(input:memoryDir:)` 直接验证路由结果，同时测试 `AgentLoopRuntime.subagentMemoryDir` 字段的携带逻辑（不需要启动真实 API）。

### Step 1: 写失败测试

**新建** `agentGuiTests/SubagentMemoryWriteIsolationTests.swift`：

```swift
import XCTest
import SwiftAnthropic
import SwiftData
@testable import agentGui

/// S-D4 验收测试：子代理 memory_write 目录作用域隔离
/// - 验证路由逻辑：subagentMemoryDir 存在时写入专属目录，nil 时写入全局目录
/// - 验证 AgentLoopRuntime 能携带 subagentMemoryDir
/// - 验证凭证内容被拒绝（凭证细节见 MemoryWriteCredentialGuardTests）
final class SubagentMemoryWriteIsolationTests: XCTestCase {

    // MARK: - 辅助

    private var globalMemDir: URL!
    private var agentMemDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-isolation-\(UUID().uuidString)")
        globalMemDir = base.appendingPathComponent("global-memory")
        agentMemDir  = base.appendingPathComponent("agent-memory/explore")
        try FileManager.default.createDirectory(at: globalMemDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentMemDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base = globalMemDir?.deletingLastPathComponent()
                                   .deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: base)
        }
    }

    private func buildInput(content: String, title: String = "Test") -> MessageResponse.Content.Input {
        ["content": .string(content), "title": .string(title)]
    }

    // MARK: - 路由测试（直接通过 executeFileMemoryWriteForTests 验证）

    func test_withAgentMemDir_writesFileToAgentDir() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "ClaudeService.swift is the main service class.", title: "ClaudeService knowledge"),
            memoryDir: agentMemDir
        )
        let filesInAgent = try FileManager.default.contentsOfDirectory(at: agentMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let filesInGlobal = try FileManager.default.contentsOfDirectory(at: globalMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }

        XCTAssertEqual(filesInAgent.count, 1, "探索代理记忆应写入 agentMemDir")
        XCTAssertEqual(filesInGlobal.count, 0, "全局目录不应有文件泄漏")
    }

    func test_withGlobalMemDir_writesFileToGlobalDir() async throws {
        let service = ClaudeService()
        _ = await service.executeFileMemoryWriteForTests(
            input: buildInput(content: "General project knowledge.", title: "General"),
            memoryDir: globalMemDir
        )
        let filesInGlobal = try FileManager.default.contentsOfDirectory(at: globalMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }
        let filesInAgent = try FileManager.default.contentsOfDirectory(at: agentMemDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "MEMORY.md" }

        XCTAssertEqual(filesInGlobal.count, 1, "全局 memory_write 应写入 globalMemDir")
        XCTAssertEqual(filesInAgent.count, 0, "代理目录不应有文件泄漏")
    }

    // MARK: - AgentLoopRuntime 字段测试

    func test_agentLoopRuntime_subagentMemoryDir_propagates() throws {
        // 用 swiftdata 内存容器构建最小 runtime
        let schema = Schema([Session.self, Message.self, ToolCall.self, AgentRound.self, AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)

        // AppSettings 构建最小实例
        let settings = AppSettings()
        settings.apiKey = "sk-ant-test"

        let expectedDir = agentMemDir!
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: "test-session",
            modelContext: ctx,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            subagentMemoryDir: expectedDir  // S-D4
        )

        XCTAssertEqual(runtime.subagentMemoryDir, expectedDir,
                       "AgentLoopRuntime 应正确携带 subagentMemoryDir")
    }

    func test_agentLoopRuntime_withoutSubagentMemoryDir_isNil() throws {
        let schema = Schema([Session.self, Message.self, ToolCall.self, AgentRound.self, AppSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let settings = AppSettings()
        settings.apiKey = "sk-ant-test"

        // 默认构造不传 subagentMemoryDir
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: "test-session",
            modelContext: ctx,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )

        XCTAssertNil(runtime.subagentMemoryDir,
                     "主代理 AgentLoopRuntime 应携带 nil 的 subagentMemoryDir（向后兼容）")
    }

    // MARK: - AgentMemoryPathResolver 集成验证（S-D1 基础已覆盖，此处确认路径计算正确）

    func test_pathResolver_userScope_computesCorrectDir() {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-resolver-\(UUID().uuidString)")
        let resolver = AgentMemoryPathResolver(agentguiBaseDir: tmpBase, workspaceRoot: nil)
        let dir = resolver.memoryDir(agentType: "explore", scope: .user)
        XCTAssertTrue(dir.path.hasSuffix("agent-memory/explore"),
                      "user scope 应解析到 agent-memory/explore 目录：\(dir.path)")
    }

    func test_pathResolver_projectScope_computesCorrectDir() {
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-resolver-project-\(UUID().uuidString)")
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd4-workspace-\(UUID().uuidString)")
        let resolver = AgentMemoryPathResolver(agentguiBaseDir: tmpBase, workspaceRoot: workspaceRoot)
        let dir = resolver.memoryDir(agentType: "explore", scope: .project)
        XCTAssertTrue(dir.path.contains(".agentgui/agent-memory/explore"),
                      "project scope 应解析到 .agentgui/agent-memory/explore：\(dir.path)")
    }

    // MARK: - S-D4 凭证保护快捷验证（详细测试见 MemoryWriteCredentialGuardTests）

    func test_credentialContent_isRejectedByExecute() async {
        let service = ClaudeService()
        let result = await service.executeFileMemoryWriteForTests(
            input: ["content": .string("My key: sk-ant-api03-secretvalue")],
            memoryDir: agentMemDir
        )
        XCTAssertTrue(result.hasPrefix("Error:"),
                      "凭证内容应被 executeFileMemoryWrite 拒绝: \(result)")
    }
}
```

### Step 2: 运行测试，确认当前状态

在 Task 2~5 完成后运行：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/SubagentMemoryWriteIsolationTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd4-task6 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：初次运行可能因 `subagentMemoryDir` 字段不存在而编译失败（Task 2 完成后解决），之后所有测试 PASS。

### Step 3: 也运行凭证测试确认仍通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/MemoryWriteCredentialGuardTests \
  -only-testing:agentGuiTests/SubagentMemoryWriteIsolationTests \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -only-testing:agentGuiTests/MemoryWriteToFileTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd4-all \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build"
```

预期：全部 PASS。

### Step 4: Commit

```bash
git add agentGuiTests/SubagentMemoryWriteIsolationTests.swift
git commit -m "test(S-D4): add subagent memory write isolation and credential guard acceptance tests"
```

---

## Task 7：回归测试（现有记忆测试套件）

确认 S-D4 改动不破坏现有记忆系统。

### Step 1: 运行记忆相关现有测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd4-regression \
  -only-testing:agentGuiTests/MemoryWriteToFileTests \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -only-testing:agentGuiTests/SubagentMemoryScopeToolInjectionTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverIntegrationTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Build succeeded"
```

预期：全部 PASS，无回归。

### Step 2: Commit 最终状态

```bash
git add -A
git commit -m "feat(S-D4): complete subagent memory_write directory isolation

- Add containsLikelyCredential() guard in executeFileMemoryWrite
- Add subagentMemoryDir: URL? to AgentLoopRuntime
- Route memory_write to subagentMemoryDir in AgentLoopToolExecutionCoordinatorBuilder
- Propagate subagentMemoryDir from runtime in runCoreAgentLoop
- Set subagentMemoryDir in runSubagentLoop when memoryScope != nil
- Tests: credential guard + isolation acceptance tests"
```

---

## 架构决策记录

### 为什么不新增 `executeTool` overload？

设计文档建议"将 `memoryDir` 从注入上下文读取"。最直接的方式是给 `executeTool` 添加 `subagentMemoryDir` 参数，但这会改变 `ClaudeService` 的公共接口，影响测试文件和所有调用点。

采用的方案（在 builder 的 `executeTool` 闭包内拦截）更符合 agentGui 现有架构：`executeTool` 闭包是 builder 局部实现细节，拦截逻辑对外不可见，且 `executeFileMemoryWriteForTests` 已是可测试 overload，无需新增接口。

### 为什么将 `subagentMemoryDir` 放在 `AgentLoopRuntime` 而非 `AgentLoopRunRequest`？

`AgentLoopRunRequest` 设计用于可序列化的 "请求参数"（tools、model、maxRounds 等），而 `AgentLoopRuntime` 携带与运行环境绑定的引用类型依赖（`ModelContext`、回调闭包等）。`URL` 属于运行环境依赖，更适合放在 `AgentLoopRuntime`，与现有的 `subagentProgressUpdate` 等字段一致。

### 凭证检测的精度策略

使用高特异性正则（要求凭证值达到最小长度）而非宽泛模式（如仅匹配单词 "key" 或 "password"），以减少误判。匹配策略对齐 OWASP 敏感数据防护原则，只拦截有置信度的凭证赋值，不影响正常代码注释或 API 文档描述。

---

## 验收检查单

- [ ] `memory_write` 在子代理 loop 中写入代理类型专属目录（`/agent-memory/<agentType>/`）
- [ ] `memory_write` 在主代理 loop 中仍写入全局目录（`~/.agentgui/memory/`）
- [ ] 无 `memoryScope` 的子代理 fallback 到全局目录（向后兼容）
- [ ] 含 `sk-ant-`、`Bearer`、`api_key =`、`password =`、`token =`、`secret =` 类凭证的内容被拒绝
- [ ] 普通叙述（含 "API key" 字样但无赋值）不被误判
- [ ] 所有现有记忆系统测试 PASS（无回归）
- [ ] `AgentLoopRuntime` 向后兼容：所有现有构造调用无需修改
