# Feature M-11: Session Memory（会话内 Notes 自动更新）Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在每轮 agent round 结束后，检查 token 阈值，满足时 fire-and-forget 启动一个 subagent 更新 `~/.agentgui/sessions/{sessionId}/session-memory/summary.md`，对齐 Claude Code `src/services/SessionMemory/` 的行为。

**Architecture:**
每个用户会话对应一个 `SessionMemoryState` actor（存储在 `ClaudeService`，按 sessionId 索引）。`SessionMemoryHook` 在每个 `willFinishRound` 阶段检查阈值；满足时委托给 `SessionMemoryService.buildCallback()` 返回的闭包，在后台 detached task 中运行 subagent（工具集：`str_replace_based_edit_tool` + `read_file`）更新 `summary.md`。会话间状态（`tokensAtLastExtraction`、`initialized` 等）跨 run 持久驻于 actor 中。

**Tech Stack:** Swift 6.0+, SwiftAnthropic, SwiftData, agentGui hook 体系（`AgentLoopHook` 协议）

**参考源码（Claude Code）：**
- `src/services/SessionMemory/sessionMemory.ts` — 主流程、`shouldExtractMemory`、`extractSessionMemory`
- `src/services/SessionMemory/sessionMemoryUtils.ts` — `SessionMemoryConfig`、`SessionMemoryState` 类比、等待逻辑
- `src/services/SessionMemory/prompts.ts` — 10 节模板（含 Worklog）、update prompt
- `src/services/awaySummary.ts` — Away Summary（M-12，本计划不涉及）

---

## 关键设计决策

### 1. `willFinishRound` Hook Stage
`AgentLoopHookStage` 当前没有 round 粒度的"结束"阶段。需新增 `willFinishRound` 并在 `AgentLoopRunner.run()` 的 while 循环体末尾 emit（`executeStreamingRound` + `applyPhaseOutcome` 完成后）。

### 2. Token 计数：基于消息快照字符估算
对齐 Claude Code `tokenCountWithEstimation(messages)` 的思路：用消息快照的总字符数除以 4 粗估 token 数。无需为 `AgentLoopSharedStateAccess` 添加新接口，也无需 API 调用。

### 3. 跨 Run 状态持久化
`SessionMemoryState` actor 存储在 `ClaudeService.sessionMemoryStates: [String: SessionMemoryState]` 字典中，key = sessionId。每次 `runCoreAgentLoop` 通过 `HookDependencyFactory` 查找/创建（复用现有 `sessionVerifications` 等字典的模式）。

### 4. Subagent 工具集
Session memory update subagent 使用 `str_replace_based_edit_tool` + `read_file` 两个工具（对齐 Claude Code FileEditTool + FileReadTool），由新增的 `ClaudeService.buildSessionMemoryTools(settings:)` 构建。

### 5. Summary.md 不注入系统提示
`summary.md` 仅供 compaction 和 away summary 读取，本 feature **不**注入系统提示，也不修改 `MemoryBootstrapHook`。

---

## 默认阈值（对齐 Claude Code DEFAULT_SESSION_MEMORY_CONFIG）

| 参数 | 值 |
|------|----|
| `minimumTokensToInit` | 10,000（估算） |
| `minimumTokensBetweenUpdate` | 5,000（增量估算） |
| `toolCallsBetweenUpdates` | 3 |

---

## 新增/修改文件一览

**新增：**
```
agentGui/Services/Memory/SessionMemory/SessionMemoryState.swift
agentGui/Services/Memory/SessionMemory/SessionMemoryPromptBuilder.swift
agentGui/Services/Memory/SessionMemory/SessionMemoryService.swift
agentGui/Services/AgentLoopHooks/SessionMemoryHook.swift
agentGuiTests/SessionMemoryStateTests.swift
agentGuiTests/SessionMemoryPromptBuilderTests.swift
agentGuiTests/SessionMemoryHookTests.swift
agentGuiTests/SessionMemoryServiceTests.swift
```

**修改：**
```
agentGui/Models/AgentLoopHookModels.swift          ← 新增 willFinishRound stage
agentGui/Utilities/ConfigDirectoryManager.swift    ← 新增 session memory 路径方法
agentGui/Services/AgentLoopRunner.swift            ← while 循环末尾 emit willFinishRound
agentGui/Services/ClaudeService/ClaudeService.swift ← 新增 sessionMemoryStates 字典
agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift ← buildSessionMemoryTools
agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift ← 传 sessionMemoryState
agentGui/Services/AgentLoopBuiltInHookFactory.swift ← 注册 SessionMemoryHook
agentGui/Services/AgentLoopHookDependencyFactory.swift ← 构建 session memory callback
agentGui/agentGui.xcodeproj/project.pbxproj        ← 新文件注册（最后 Task）
```

---

## Task 1：新增 `willFinishRound` Hook Stage

**Files:**
- Modify: `agentGui/Models/AgentLoopHookModels.swift`
- Modify: `agentGui/Services/AgentLoopRunner.swift`

### Step 1: 在 `AgentLoopHookStage` 枚举中添加新 case

打开 `agentGui/Models/AgentLoopHookModels.swift`，在 `didAppendToolResults` 之后、`decideFinalization` 之前插入：

```swift
// 现有片段（精确定位）：
    case didAppendToolResults
    case classifyFailureTrigger
```

修改为：
```swift
    case didAppendToolResults
    /// 每个 agent round 完整结束后（executeStreamingRound + applyPhaseOutcome 均完成）。
    /// 供 SessionMemoryHook 等需要 round 粒度触发的 hook 使用。
    case willFinishRound
    case classifyFailureTrigger
```

### Step 2: 在 `AgentLoopRunner.run()` 的 while 循环末尾 emit

打开 `agentGui/Services/AgentLoopRunner.swift`，找到 while 循环：

```swift
// 现有代码（精确定位）：
                while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
                        try Task.checkCancellation()

                        let outcome = try await roundExecutor.executeStreamingRound(state: &state, messages: &messages)
                        try await roundExecutor.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)
                }
```

修改为：
```swift
                while state.loopCtx.shouldContinue && state.loopCtx.roundIndex < request.maxRounds {
                        try Task.checkCancellation()

                        let outcome = try await roundExecutor.executeStreamingRound(state: &state, messages: &messages)
                        try await roundExecutor.applyPhaseOutcome(outcome: outcome, state: &state, messages: &messages)

                        // Session Memory hook：每轮结束后检查阈值
                        await emitter.emit(
                                .willFinishRound,
                                state: state,
                                messages: messages,
                                overrides: .init(metadata: [
                                        "roundIndex": state.loopCtx.roundIndex,
                                        "toolCallsThisRound": outcome.pendingTools.count
                                ])
                        )
                }
```

### Step 3: 验证编译

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 4: Commit

```bash
git add agentGui/Models/AgentLoopHookModels.swift agentGui/Services/AgentLoopRunner.swift
git commit -m "feat(M-11): add willFinishRound hook stage + emit in AgentLoopRunner"
```

---

## Task 2：扩展 `ConfigDirectoryManager` 添加 Session Memory 路径

**Files:**
- Modify: `agentGui/Utilities/ConfigDirectoryManager.swift`

### Step 1: 写失败测试

新建 `agentGuiTests/SessionMemoryPathTests.swift`：

```swift
import XCTest
@testable import agentGui

final class SessionMemoryPathTests: XCTestCase {

    func test_sessionMemoryDir_returnsExpectedPath() {
        let mgr = ConfigDirectoryManager.shared
        let dir = mgr.sessionMemoryDir(sessionId: "abc-123")
        XCTAssertTrue(dir.path.hasSuffix("/.agentgui/sessions/abc-123/session-memory"))
    }

    func test_sessionMemorySummaryURL_returnsExpectedPath() {
        let mgr = ConfigDirectoryManager.shared
        let url = mgr.sessionMemorySummaryURL(sessionId: "abc-123")
        XCTAssertTrue(url.path.hasSuffix("/.agentgui/sessions/abc-123/session-memory/summary.md"))
    }

    func test_sessionMemorySummaryURL_uniquePerSession() {
        let mgr = ConfigDirectoryManager.shared
        let url1 = mgr.sessionMemorySummaryURL(sessionId: "session-1")
        let url2 = mgr.sessionMemorySummaryURL(sessionId: "session-2")
        XCTAssertNotEqual(url1, url2)
    }
}
```

### Step 2: 运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryPathTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: 编译失败（方法不存在）

### Step 3: 实现路径方法

在 `agentGui/Utilities/ConfigDirectoryManager.swift` 的 `// MARK: - Paths` 节末尾（`var memoryIndexURL` 之后）添加：

```swift
    /// `~/.agentgui/sessions/{sessionId}/session-memory/`
    func sessionMemoryDir(sessionId: String) -> URL {
        agentGuiDir
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("session-memory", isDirectory: true)
    }

    /// `~/.agentgui/sessions/{sessionId}/session-memory/summary.md`
    func sessionMemorySummaryURL(sessionId: String) -> URL {
        sessionMemoryDir(sessionId: sessionId)
            .appendingPathComponent("summary.md")
    }
```

### Step 4: 运行确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryPathTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Utilities/ConfigDirectoryManager.swift agentGuiTests/SessionMemoryPathTests.swift
git commit -m "feat(M-11): add sessionMemoryDir/summaryURL to ConfigDirectoryManager"
```

---

## Task 3：创建 `SessionMemoryState` Actor

**Files:**
- Create: `agentGui/Services/Memory/SessionMemory/SessionMemoryState.swift`
- Create: `agentGuiTests/SessionMemoryStateTests.swift`

### Step 1: 写失败测试

新建 `agentGuiTests/SessionMemoryStateTests.swift`：

```swift
import XCTest
@testable import agentGui

final class SessionMemoryStateTests: XCTestCase {

    // MARK: - 初始化阈值

    func test_shouldExtract_belowInitThreshold_returnsFalse() async {
        let state = SessionMemoryState()
        // 9,999 tokens < 10,000 init threshold
        let result = await state.shouldExtract(estimatedTokens: 9_999, toolCallsThisRound: 5)
        XCTAssertFalse(result)
    }

    func test_shouldExtract_atInitThreshold_returnsTrue_whenToolCallsMet() async {
        let state = SessionMemoryState()
        // 首次达到 10,000，且 toolCalls >= 3
        let result = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        XCTAssertTrue(result)
    }

    func test_shouldExtract_afterInit_belowTokenUpdateThreshold_returnsFalse() async {
        let state = SessionMemoryState()
        // 第一次触发（初始化）
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 增量 < 5,000（仅增加 4,999）
        let result = await state.shouldExtract(estimatedTokens: 14_999, toolCallsThisRound: 3)
        XCTAssertFalse(result)
    }

    func test_shouldExtract_afterInit_meetsTokenAndToolThreshold_returnsTrue() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 增量 = 5,000，且累计工具调用 >= 3
        let result = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 3)
        XCTAssertTrue(result)
    }

    func test_shouldExtract_noToolCallsInRound_meetsTokenThreshold_returnsTrue() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)

        // 无工具调用 + 满足 token 增量 → 对齐 Claude Code "natural conversation break"
        let result = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 0)
        XCTAssertTrue(result)
    }

    func test_recordExtraction_resetsToolCallCounter() async {
        let state = SessionMemoryState()
        _ = await state.shouldExtract(estimatedTokens: 10_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 10_000)
        _ = await state.shouldExtract(estimatedTokens: 15_000, toolCallsThisRound: 3)
        await state.recordExtraction(estimatedTokens: 15_000)

        // 重置后，工具调用计数从 0 开始，还需要再累计 3 次才满足
        let result = await state.shouldExtract(estimatedTokens: 20_000, toolCallsThisRound: 2)
        XCTAssertFalse(result)
    }

    func test_extractionInProgress_preventsConcurrentExtraction() async {
        let state = SessionMemoryState()
        let acquired = await state.beginExtraction()
        XCTAssertTrue(acquired)
        let rejected = await state.beginExtraction()
        XCTAssertFalse(rejected)
        await state.finishExtraction()
        let acquiredAgain = await state.beginExtraction()
        XCTAssertTrue(acquiredAgain)
    }

    func test_waitForExtraction_returnsWhenCompleted() async {
        let state = SessionMemoryState()
        _ = await state.beginExtraction()

        let waitTask = Task {
            await state.waitForExtraction(timeout: 2.0)
        }

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await state.finishExtraction()
        await waitTask.value
        // 通过不超时即为 pass
    }
}
```

### Step 2: 运行确认失败（类型不存在）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryStateTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD FAILED" | head -10
```

Expected: 编译错误（`SessionMemoryState` 不存在）

### Step 3: 实现 `SessionMemoryState`

新建 `agentGui/Services/Memory/SessionMemory/SessionMemoryState.swift`：

```swift
import Foundation

/// 对齐 Claude Code `sessionMemoryUtils.ts` 中的模块级状态变量。
///
/// 以 actor 形式封装每个 session 的 session memory 提取状态，
/// 跨 `runCoreAgentLoop` 调用持久驻留（存放在 `ClaudeService.sessionMemoryStates`）。
actor SessionMemoryState {

    // MARK: - Config（对齐 Claude Code DEFAULT_SESSION_MEMORY_CONFIG）

    static let minimumTokensToInit = 10_000
    static let minimumTokensBetweenUpdate = 5_000
    static let toolCallsBetweenUpdates = 3

    // MARK: - State

    private var initialized = false
    private var tokensAtLastExtraction = 0
    private var toolCallsSinceLastExtraction = 0
    private var extractionInProgress = false
    private var extractionStartedAt: Date?

    // MARK: - Extraction Gate

    /// 检查是否应触发 session memory 更新。
    ///
    /// 对齐 Claude Code `shouldExtractMemory`：
    /// - 首次需满足 init 阈值
    /// - 此后需满足 token 增量阈值，且（tool call 阈值满足 OR 无工具调用的自然对话断点）
    func shouldExtract(estimatedTokens: Int, toolCallsThisRound: Int) -> Bool {
        toolCallsSinceLastExtraction += toolCallsThisRound

        if !initialized {
            guard estimatedTokens >= Self.minimumTokensToInit else { return false }
            initialized = true
        }

        let tokenGrowth = estimatedTokens - tokensAtLastExtraction
        let hasMetTokenThreshold = tokenGrowth >= Self.minimumTokensBetweenUpdate
        guard hasMetTokenThreshold else { return false }

        let hasMetToolCallThreshold = toolCallsSinceLastExtraction >= Self.toolCallsBetweenUpdates
        let isNaturalBreak = (toolCallsThisRound == 0)

        return hasMetToolCallThreshold || isNaturalBreak
    }

    /// 提取完成后调用，更新 token 基线并重置工具调用计数。
    func recordExtraction(estimatedTokens: Int) {
        tokensAtLastExtraction = estimatedTokens
        toolCallsSinceLastExtraction = 0
    }

    // MARK: - Concurrency Guard（对齐 Claude Code sequential + extractionStartedAt 机制）

    /// 尝试开始提取。若已有提取在进行中则返回 false。
    func beginExtraction() -> Bool {
        guard !extractionInProgress else { return false }
        extractionInProgress = true
        extractionStartedAt = Date()
        return true
    }

    /// 标记提取完成。
    func finishExtraction() {
        extractionInProgress = false
        extractionStartedAt = nil
    }

    /// 等待当前提取完成（带超时）。对齐 Claude Code `waitForSessionMemoryExtraction`。
    func waitForExtraction(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while extractionInProgress {
            guard Date() < deadline else { return }
            // 过期检测：>1 分钟的提取视为 stale
            if let startedAt = extractionStartedAt,
               Date().timeIntervalSince(startedAt) > 60 {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms poll
        }
    }

    // MARK: - Token Estimation（对齐 Claude Code tokenCountWithEstimation）

    static func estimateTokens(from messages: [any Sendable]) -> Int {
        // Swift 版本：使用 Mirror 提取文本内容并以 chars/4 估算
        // 实际调用方传入 [MessageParameter.Message]，在 SessionMemoryService 中进行类型化
        0 // 占位，由 SessionMemoryService 中的类型化版本实现
    }
}
```

> **注意**：`estimateTokens(from:)` 的实际实现在 Task 6（`SessionMemoryService`）中提供，因为它需要 `MessageParameter.Message` 类型（在本文件中避免导入 SwiftAnthropic 造成循环依赖）。

### Step 4: 注册文件到 Xcode（pbxproj）

```bash
# 暂跳过，Task 10 统一注册所有新文件
```

### Step 5: 运行确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryStateTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 6: Commit

```bash
git add agentGui/Services/Memory/SessionMemory/SessionMemoryState.swift agentGuiTests/SessionMemoryStateTests.swift
git commit -m "feat(M-11): add SessionMemoryState actor with threshold logic"
```

---

## Task 4：创建 `SessionMemoryPromptBuilder`

**Files:**
- Create: `agentGui/Services/Memory/SessionMemory/SessionMemoryPromptBuilder.swift`
- Create: `agentGuiTests/SessionMemoryPromptBuilderTests.swift`

### Step 1: 写失败测试

新建 `agentGuiTests/SessionMemoryPromptBuilderTests.swift`：

```swift
import XCTest
@testable import agentGui

final class SessionMemoryPromptBuilderTests: XCTestCase {

    func test_defaultTemplate_containsAllTenSections() {
        let template = SessionMemoryPromptBuilder.defaultTemplate
        let expectedSections = [
            "# Session Title",
            "# Current State",
            "# Task specification",
            "# Files and Functions",
            "# Workflow",
            "# Errors & Corrections",
            "# Codebase and System Documentation",
            "# Learnings",
            "# Key results",
            "# Worklog"
        ]
        for section in expectedSections {
            XCTAssertTrue(template.contains(section), "Template missing: \(section)")
        }
    }

    func test_buildUpdatePrompt_containsNotesPath() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "# Session Title\n_placeholder_",
            notesPath: "/path/to/summary.md"
        )
        XCTAssertTrue(prompt.contains("/path/to/summary.md"))
    }

    func test_buildUpdatePrompt_containsCurrentNotesContent() {
        let currentNotes = "# Session Title\n_placeholder_\n\nSome existing content"
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: currentNotes,
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("Some existing content"))
    }

    func test_buildUpdatePrompt_instructsParallelEdits() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "",
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("parallel") || prompt.contains("single message"))
    }

    func test_buildUpdatePrompt_prohibitsModifyingSectionHeaders() {
        let prompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: "",
            notesPath: "/tmp/summary.md"
        )
        XCTAssertTrue(prompt.contains("NEVER modify") || prompt.contains("section headers"))
    }

    func test_loadCustomTemplate_returnsDefaultWhenFileAbsent() async {
        let nonExistentDir = URL(fileURLWithPath: "/tmp/nonexistent-agentgui-\(UUID().uuidString)")
        let template = await SessionMemoryPromptBuilder.loadTemplate(configDir: nonExistentDir)
        XCTAssertEqual(template, SessionMemoryPromptBuilder.defaultTemplate)
    }

    func test_loadCustomTemplate_loadsFromFile() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-template-test-\(UUID().uuidString)", isDirectory: true)
        let configPath = tmpDir
            .appendingPathComponent("session-memory", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configPath, withIntermediateDirectories: true)
        let templateURL = configPath.appendingPathComponent("template.md")
        try "# Custom Template\n_my section_".write(to: templateURL, atomically: true, encoding: .utf8)

        let template = await SessionMemoryPromptBuilder.loadTemplate(configDir: tmpDir)
        XCTAssertEqual(template, "# Custom Template\n_my section_")
    }
}
```

### Step 2: 运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryPromptBuilderTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 3: 实现 `SessionMemoryPromptBuilder`

新建 `agentGui/Services/Memory/SessionMemory/SessionMemoryPromptBuilder.swift`：

```swift
import Foundation

/// 构建 session memory 更新 prompt 和默认 9 节模板。
///
/// 对齐 Claude Code `src/services/SessionMemory/prompts.ts`：
/// - `DEFAULT_SESSION_MEMORY_TEMPLATE`（10 节，包含 Worklog）
/// - `buildSessionMemoryUpdatePrompt`
/// - `loadSessionMemoryTemplate`（支持自定义模板覆盖）
struct SessionMemoryPromptBuilder: Sendable {

    private static let maxSectionLength = 2000

    // MARK: - Default Template

    /// 对齐 Claude Code `DEFAULT_SESSION_MEMORY_TEMPLATE`（10 节）
    static let defaultTemplate: String = """
        # Session Title
        _A short and distinctive 5-10 word descriptive title for the session. Super info dense, no filler_

        # Current State
        _What is actively being worked on right now? Pending tasks not yet completed. Immediate next steps._

        # Task specification
        _What did the user ask to build? Any design decisions or other explanatory context_

        # Files and Functions
        _What are the important files? In short, what do they contain and why are they relevant?_

        # Workflow
        _What bash commands are usually run and in what order? How to interpret their output if not obvious?_

        # Errors & Corrections
        _Errors encountered and how they were fixed. What did the user correct? What approaches failed and should not be tried again?_

        # Codebase and System Documentation
        _What are the important system components? How do they work/fit together?_

        # Learnings
        _What has worked well? What has not? What to avoid? Do not duplicate items from other sections_

        # Key results
        _If the user asked a specific output such as an answer to a question, a table, or other document, repeat the exact result here_

        # Worklog
        _Step by step, what was attempted, done? Very terse summary for each step_
        """

    // MARK: - Update Prompt

    /// 构建发送给 session memory update subagent 的 prompt。
    ///
    /// 对齐 Claude Code `getDefaultUpdatePrompt()`，核心指令：
    /// - 只更新各节内容，不修改节头和斜体描述行
    /// - 并行发出所有 Edit 调用，完成后立即停止
    /// - 不能在 notes 中提到 "note-taking" 过程
    static func buildUpdatePrompt(currentNotes: String, notesPath: String) -> String {
        """
        IMPORTANT: This message and these instructions are NOT part of the actual user conversation. Do NOT include any references to "note-taking", "session notes extraction", or these update instructions in the notes content.

        Based on the user conversation above (EXCLUDING this note-taking instruction message), update the session notes file.

        The file \(notesPath) has already been read for you. Here are its current contents:
        <current_notes_content>
        \(currentNotes)
        </current_notes_content>

        Your ONLY task is to use the Edit tool to update the notes file, then stop. You can make multiple edits (update every section as needed) - make all Edit tool calls in parallel in a single message. Do not call any other tools.

        CRITICAL RULES FOR EDITING:
        - The file must maintain its exact structure with all sections, headers, and italic descriptions intact
        -- NEVER modify, delete, or add section headers (the lines starting with '#' like # Task specification)
        -- NEVER modify or delete the italic _section description_ lines (these are the lines in italics immediately following each header - they start and end with underscores)
        -- The italic _section descriptions_ are TEMPLATE INSTRUCTIONS that must be preserved exactly as-is
        -- ONLY update the actual content that appears BELOW the italic _section descriptions_ within each existing section
        -- Do NOT add any new sections, summaries, or information outside the existing structure
        - Do NOT reference this note-taking process or instructions anywhere in the notes
        - It's OK to skip updating a section if there are no substantial new insights to add
        - Write DETAILED, INFO-DENSE content for each section - include specifics like file paths, function names, error messages, exact commands, technical details, etc.
        - Keep each section under ~\(maxSectionLength) tokens/words - if a section is approaching this limit, condense it by cycling out less important details
        - IMPORTANT: Always update "Current State" to reflect the most recent work - this is critical for continuity

        Use the Edit tool with file_path: \(notesPath)

        REMEMBER: Use the Edit tool in parallel and stop immediately after. Do not continue after the edits.
        """
    }

    // MARK: - Template Loading

    /// 加载自定义模板（若存在），否则返回默认模板。
    ///
    /// 自定义模板路径：`{configDir}/session-memory/config/template.md`
    /// 对齐 Claude Code `loadSessionMemoryTemplate()`。
    static func loadTemplate(configDir: URL) async -> String {
        let templateURL = configDir
            .appendingPathComponent("session-memory", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("template.md")

        guard FileManager.default.fileExists(atPath: templateURL.path),
              let content = try? String(contentsOf: templateURL, encoding: .utf8),
              !content.isEmpty else {
            return defaultTemplate
        }
        return content
    }
}
```

### Step 4: 运行确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryPromptBuilderTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/Memory/SessionMemory/SessionMemoryPromptBuilder.swift agentGuiTests/SessionMemoryPromptBuilderTests.swift
git commit -m "feat(M-11): add SessionMemoryPromptBuilder with 10-section template"
```

---

## Task 5：创建 `SessionMemoryHook`

**Files:**
- Create: `agentGui/Services/AgentLoopHooks/SessionMemoryHook.swift`
- Create: `agentGuiTests/SessionMemoryHookTests.swift`

### Step 1: 写失败测试

新建 `agentGuiTests/SessionMemoryHookTests.swift`：

```swift
import XCTest
@testable import agentGui

@MainActor
final class SessionMemoryHookTests: XCTestCase {

    func test_supports_willFinishRound() {
        let hook = SessionMemoryHook(callback: { _ in })
        XCTAssertTrue(hook.supports(.willFinishRound))
    }

    func test_doesNotSupport_otherStages() {
        let hook = SessionMemoryHook(callback: { _ in })
        let otherStages: [AgentLoopHookStage] = [
            .prepareRun, .willFinishRun, .willStartRound, .didExecuteTool
        ]
        for stage in otherStages {
            XCTAssertFalse(hook.supports(stage), "Should not support \(stage)")
        }
    }

    func test_perform_firesCallback_forMainAgent() async throws {
        let exp = XCTestExpectation(description: "callback fired")
        let hook = SessionMemoryHook(callback: { _ in exp.fulfill() })

        let context = makeTestContext(toolExecutionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        await fulfillment(of: [exp], timeout: 2.0)
    }

    func test_perform_skipsCallback_forSubagent() async throws {
        var callbackFired = false
        let hook = SessionMemoryHook(callback: { _ in callbackFired = true })

        let context = makeTestContext(toolExecutionContext: .subagent)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackFired)
    }

    func test_perform_skipsCallback_forBackgroundTask() async throws {
        var callbackFired = false
        let hook = SessionMemoryHook(callback: { _ in callbackFired = true })

        let context = makeTestContext(toolExecutionContext: .backgroundTask)
        let result = try await hook.perform(stage: .willFinishRound, context: context)

        XCTAssertEqual(result, .continue)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(callbackFired)
    }

    func test_hookMetadata() {
        let hook = SessionMemoryHook(callback: { _ in })
        XCTAssertEqual(hook.id, "session-memory")
        XCTAssertEqual(hook.order, 85)
        XCTAssertEqual(hook.kind, .observer)
        XCTAssertFalse(hook.isRequired)
    }

    // MARK: - Helpers

    private func makeTestContext(toolExecutionContext: ToolContext) -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "test-run",
            sessionID: "test-session",
            workflowID: nil,
            executionContext: toolExecutionContext,
            modelId: "claude-sonnet-4-5",
            roundIndex: 2,
            phase: "finalizing"
        )
    }
}
```

### Step 2: 运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryHookTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 3: 实现 `SessionMemoryHook`

新建 `agentGui/Services/AgentLoopHooks/SessionMemoryHook.swift`：

```swift
import Foundation

/// 在每个 `willFinishRound` 阶段检查 session memory 更新阈值。
///
/// 精确对齐 Claude Code `extractSessionMemory` postSamplingHook 的行为：
/// - 只对主 agent run（`.mainAgent` 执行上下文）触发
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际提取通过注入的 `callback` 闭包执行（fire-and-forget detached task）
/// - order = 85（在 MemoryExtractionHook(90) 之前）
struct SessionMemoryHook: AgentLoopHook {
    let id = "session-memory"
    let order = 85
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    /// Injected callback: 由 `SessionMemoryService.buildCallback()` 构建，
    /// 内部负责阈值检查和 subagent 更新逻辑。
    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRound
    }

    func perform(
        stage: AgentLoopHookStage,
        context: AgentLoopHookContext
    ) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRound else { return .continue }

        // 只对主 agent run 触发（对齐 Claude Code querySource === 'repl_main_thread' 守卫）
        guard context.executionContext == .mainAgent else { return .continue }

        // Fire-and-forget：不等待提取完成，立即放行 main loop
        let capturedContext = context
        let capturedCallback = callback
        Task.detached(priority: .background) {
            await capturedCallback(capturedContext)
        }

        return .continue
    }
}
```

### Step 4: 运行确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryHookTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/AgentLoopHooks/SessionMemoryHook.swift agentGuiTests/SessionMemoryHookTests.swift
git commit -m "feat(M-11): add SessionMemoryHook (willFinishRound, order=85)"
```

---

## Task 6：创建 `SessionMemoryService`

**Files:**
- Create: `agentGui/Services/Memory/SessionMemory/SessionMemoryService.swift`
- Create: `agentGuiTests/SessionMemoryServiceTests.swift`

### Step 1: 写失败测试

新建 `agentGuiTests/SessionMemoryServiceTests.swift`：

```swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class SessionMemoryServiceTests: XCTestCase {

    // MARK: - Token Estimation

    func test_estimateTokens_emptyMessages_returnsZero() {
        let messages: [MessageParameter.Message] = []
        XCTAssertEqual(SessionMemoryService.estimateTokens(from: messages), 0)
    }

    func test_estimateTokens_singleTextMessage_approximatesCharDividedByFour() {
        let text = String(repeating: "a", count: 400)
        let messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text(text))
        ]
        let estimate = SessionMemoryService.estimateTokens(from: messages)
        XCTAssertEqual(estimate, 100, accuracy: 10)   // 400 chars / 4 ≈ 100
    }

    // MARK: - Summary File Initialization

    func test_ensureSummaryFileExists_createsFileWithTemplate() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-init-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let summaryURL = tmpDir.appendingPathComponent("summary.md")
        let template = "# Test Template\n_placeholder_"

        try await SessionMemoryService.ensureSummaryFileExists(at: summaryURL, template: template)

        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
        let content = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertEqual(content, template)
    }

    func test_ensureSummaryFileExists_doesNotOverwriteExistingFile() async throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-nooverwrite-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let summaryURL = tmpDir.appendingPathComponent("summary.md")
        let existingContent = "# Existing Content\n\nSome notes"
        try existingContent.write(to: summaryURL, atomically: true, encoding: .utf8)

        let template = "# Fresh Template"
        try await SessionMemoryService.ensureSummaryFileExists(at: summaryURL, template: template)

        let content = try String(contentsOf: summaryURL, encoding: .utf8)
        XCTAssertEqual(content, existingContent, "Existing file must not be overwritten")
    }

    func test_readSummaryContent_returnsNilForMissingFile() async {
        let nonExistent = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)/summary.md")
        let content = await SessionMemoryService.readSummaryContent(at: nonExistent)
        XCTAssertNil(content)
    }

    func test_readSummaryContent_returnsFileContent() async throws {
        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("summary-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        try "# My Notes\n\nContent here".write(to: tmpFile, atomically: true, encoding: .utf8)

        let content = await SessionMemoryService.readSummaryContent(at: tmpFile)
        XCTAssertEqual(content, "# My Notes\n\nContent here")
    }
}
```

### Step 2: 运行确认失败

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 3: 实现 `SessionMemoryService`

新建 `agentGui/Services/Memory/SessionMemory/SessionMemoryService.swift`：

```swift
import Foundation
import SwiftAnthropic
import SwiftData

/// Session Memory 更新服务。
///
/// 职责：
/// 1. 检查 token/tool call 阈值（委托给 `SessionMemoryState`）
/// 2. 初始化 `summary.md`（首次时写入模板）
/// 3. 读取当前 notes 内容
/// 4. 启动 subagent（`str_replace_based_edit_tool` + `read_file`）更新 notes
///
/// 对齐 Claude Code `extractSessionMemory` + `setupSessionMemoryFile`。
struct SessionMemoryService: Sendable {

    let claudeService: ClaudeService
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext
    let sessionMemoryState: SessionMemoryState

    // MARK: - Public: Callback Builder

    /// 构建 hook callback，供 `SessionMemoryHook` 使用。
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let capturedService = claudeService
        let capturedSettings = settings
        let capturedSessionId = sessionId
        let capturedModelContext = modelContext
        let capturedState = sessionMemoryState

        return { @Sendable context in
            let estimatedTokens = SessionMemoryService.estimateTokens(from: context.messagesSnapshot)
            let toolCallsThisRound = (context.metadata["toolCallsThisRound"] as? Int) ?? 0

            guard await capturedState.shouldExtract(
                estimatedTokens: estimatedTokens,
                toolCallsThisRound: toolCallsThisRound
            ) else { return }

            guard await capturedState.beginExtraction() else { return }
            defer { Task { await capturedState.finishExtraction() } }

            do {
                try await SessionMemoryService.performUpdate(
                    context: context,
                    claudeService: capturedService,
                    settings: capturedSettings,
                    sessionId: capturedSessionId,
                    modelContext: capturedModelContext
                )
                await capturedState.recordExtraction(estimatedTokens: estimatedTokens)
            } catch {
                #if DEBUG
                print("[SessionMemoryService] update error: \(error)")
                #endif
            }
        }
    }

    // MARK: - Internal: Core Update Logic

    static func performUpdate(
        context: AgentLoopHookContext,
        claudeService: ClaudeService,
        settings: AppSettings,
        sessionId: String,
        modelContext: ModelContext
    ) async throws {
        let summaryURL = ConfigDirectoryManager.shared.sessionMemorySummaryURL(sessionId: sessionId)

        // 1. 加载模板（支持自定义）
        let template = await SessionMemoryPromptBuilder.loadTemplate(
            configDir: ConfigDirectoryManager.shared.agentGuiDir
        )

        // 2. 初始化 summary.md（不覆盖已有内容）
        try await ensureSummaryFileExists(at: summaryURL, template: template)

        // 3. 读取当前 notes
        let currentNotes = (await readSummaryContent(at: summaryURL)) ?? template

        // 4. 构建 update prompt
        let updatePrompt = SessionMemoryPromptBuilder.buildUpdatePrompt(
            currentNotes: currentNotes,
            notesPath: summaryURL.path
        )

        // 5. 构建受限工具集：str_replace_based_edit_tool + read_file
        let tools = await claudeService.buildSessionMemoryTools(settings: settings)
        guard !tools.isEmpty else { return }

        // 6. 组装消息：对话快照 + update prompt
        var loopMessages = context.messagesSnapshot
        loopMessages.append(.init(role: .user, content: .text(updatePrompt)))

        guard let service = await claudeService.service else { return }

        // 7. 启动 subagent（对齐 Claude Code runForkedAgent，单次完成后停止）
        let request = AgentLoopRunRequest(
            service: service,
            modelId: settings.selectedModel,
            tools: tools,
            system: await claudeService.makeEphemeralSystemPrompt(""),
            maxRounds: 3,
            toolExecutionContext: .backgroundTask,
            toolApprovalMode: .bypassApprovals,
            runSource: "sessionMemory",
            runLabel: "Session memory update",
            requestedBudgetSeconds: nil
        )
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: sessionId,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            remoteDeliveryHandle: nil
        )

        _ = try await claudeService.runCoreAgentLoop(
            messages: &loopMessages,
            request: request,
            runtime: runtime
        )
    }

    // MARK: - Internal: File Helpers

    /// 确保 `summary.md` 存在。若不存在则创建并写入模板；若已存在则不修改。
    static func ensureSummaryFileExists(at url: URL, template: String) async throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        guard !fm.fileExists(atPath: url.path) else { return }
        try template.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读取 `summary.md` 内容。文件不存在时返回 nil。
    static func readSummaryContent(at url: URL) async -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Internal: Token Estimation

    /// 粗估消息列表的 token 数。
    ///
    /// 对齐 Claude Code `tokenCountWithEstimation`：chars / 4（不调用 API，纯本地估算）。
    static func estimateTokens(from messages: [MessageParameter.Message]) -> Int {
        let totalChars = messages.reduce(0) { acc, msg in
            acc + messageCharCount(msg)
        }
        return totalChars / 4
    }

    private static func messageCharCount(_ msg: MessageParameter.Message) -> Int {
        switch msg.content {
        case .text(let t):
            return t.count
        case .list(let items):
            return items.reduce(0) { acc, item in
                switch item {
                case .text(let t): return acc + t.text.count
                case .toolResult(let r):
                    switch r.content {
                    case .text(let t): return acc + t.count
                    case .list(let blocks):
                        return acc + blocks.reduce(0) { $0 + ($1.text?.count ?? 0) }
                    }
                default: return acc
                }
            }
        }
    }
}
```

### Step 4: 运行确认通过

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SessionMemoryServiceTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`

### Step 5: Commit

```bash
git add agentGui/Services/Memory/SessionMemory/SessionMemoryService.swift agentGuiTests/SessionMemoryServiceTests.swift
git commit -m "feat(M-11): add SessionMemoryService with subagent orchestration"
```

---

## Task 7：添加 `buildSessionMemoryTools` 到 `ClaudeService+ToolBuilder`

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`

### Step 1: 在 `buildExtractionTools` 之后添加新方法

打开 `agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift`，在 `buildExtractionTools(settings:)` 和 `toolNameForExtraction(from:)` 方法之间插入：

```swift
    /// 构建 session memory update subagent 的受限工具集。
    ///
    /// 仅包含：
    /// - `str_replace_based_edit_tool`（EditTool，用于更新 summary.md 各节内容）
    /// - `read_file`（ReadTool，用于读取 summary.md 当前内容作为上下文）
    ///
    /// 对齐 Claude Code 中 forked agent 使用 FileEditTool + FileReadTool 的模式。
    func buildSessionMemoryTools(settings: AppSettings) -> [MessageParameter.Tool] {
        let allowed: Set<String> = ["str_replace_based_edit_tool", "read_file"]
        let allTools = buildTools(modelId: settings.selectedModel, settings: settings)
        return allTools.filter { tool in
            toolNameForExtraction(from: tool).map { allowed.contains($0) } ?? false
        }
    }
```

### Step 2: 验证编译

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 3: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift
git commit -m "feat(M-11): add buildSessionMemoryTools to ClaudeService"
```

---

## Task 8：添加 `sessionMemoryStates` 到 `ClaudeService`

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift`

### Step 1: 在 `ClaudeService` 中添加 per-session state 存储

打开 `agentGui/Services/ClaudeService/ClaudeService.swift`，找到类似 `var sessionVerifications` 的字典集合区块，在其后添加：

```swift
    // MARK: - Session Memory State（M-11）

    /// Per-session session memory 状态。
    /// 跨 runCoreAgentLoop 调用持久驻留，key = sessionId。
    ///
    /// 对齐 Claude Code 的模块级 `sessionMemoryInitialized`、`tokensAtLastExtraction` 等变量。
    private var sessionMemoryStates: [String: SessionMemoryState] = [:]

    /// 获取或创建指定 session 的 `SessionMemoryState` actor。
    func sessionMemoryState(for sessionId: String) -> SessionMemoryState {
        if let existing = sessionMemoryStates[sessionId] { return existing }
        let newState = SessionMemoryState()
        sessionMemoryStates[sessionId] = newState
        return newState
    }
```

> **注意**：`ClaudeService` 是 `@MainActor`，字典访问是安全的。

### Step 2: 验证编译

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 3: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift
git commit -m "feat(M-11): add per-session SessionMemoryState storage to ClaudeService"
```

---

## Task 9：Wire 进 `AgentLoopBuiltInHookFactory` + `AgentLoopHookDependencyFactory`

**Files:**
- Modify: `agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`

### Step 1: 更新 `AgentLoopBuiltInHookFactory`

打开 `agentGui/Services/AgentLoopBuiltInHookFactory.swift`：

1. 在 `Dependencies` 结构体中新增字段（在 `memoryRecallService` 之后）：

```swift
        // M-11: 会话内 session memory 自动更新回调
        let sessionMemoryCallback: @Sendable (AgentLoopHookContext) async -> Void
```

2. 在 `makeHooks` 返回的数组中，在 `MemoryExtractionHook` 之前插入：

```swift
            // M-11: 每轮结束后更新 session memory notes
            SessionMemoryHook(callback: dependencies.sessionMemoryCallback),
```

完整修改后的 `makeHooks` 返回值：
```swift
        [
            StreamProjectionHook(),
            RemoteChannelProjectionHook(),
            MemoryBootstrapHook { _ in
                try await dependencies.memoryBootstrapLoader(state)
            },
            ToolAuditHook(...),
            FailureClassificationHook(),
            BusinessObservabilityHook(sink: dependencies.businessLogSink),
            // M-11: 每轮结束后更新 session memory notes（order=85，在 ExtractionHook(90) 前）
            SessionMemoryHook(callback: dependencies.sessionMemoryCallback),
            // M-03: 会话末记忆自动提取
            MemoryExtractionHook(callback: dependencies.extractMemoriesCallback),
            // M-05: 中段记忆召回
            MemoryRecallHook(recallService: dependencies.memoryRecallService),
        ]
```

### Step 2: 更新 `AgentLoopHookDependencyFactory`

打开 `agentGui/Services/AgentLoopHookDependencyFactory.swift`：

1. 在 `build(state:)` 方法中，在 `extractMemoriesCallback` 之后添加：

```swift
            // M-11
            sessionMemoryCallback: buildSessionMemoryCallback(),
```

2. 在 `buildExtractionCallback()` 之后添加新私有方法：

```swift
    /// 构建 session memory 更新闭包（M-11）。
    private func buildSessionMemoryCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let sessionMemoryState = claudeService.sessionMemoryState(for: runtime.sessionId)
        return SessionMemoryService(
            claudeService: claudeService,
            settings: runtime.settings,
            sessionId: runtime.sessionId,
            modelContext: runtime.modelContext,
            sessionMemoryState: sessionMemoryState
        ).buildCallback()
    }
```

### Step 3: 验证编译

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

### Step 4: Commit

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift agentGui/Services/AgentLoopHookDependencyFactory.swift
git commit -m "feat(M-11): wire SessionMemoryHook into hook factory"
```

---

## Task 10：注册新文件到 Xcode project

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`

### Step 1: 在 Xcode 中添加新文件

打开 Xcode（`open agentGui.xcodeproj`），然后：

1. 右键点击 `agentGui/Services/Memory/` → `New Group` → 命名为 `SessionMemory`
2. 右键点击 `SessionMemory` 组 → `Add Files to "agentGui"` → 选择以下文件（勾选 target `agentGui`）：
   - `SessionMemoryState.swift`
   - `SessionMemoryPromptBuilder.swift`
   - `SessionMemoryService.swift`
3. 右键点击 `agentGui/Services/AgentLoopHooks/` → `Add Files to "agentGui"` → 选择：
   - `SessionMemoryHook.swift`（target: `agentGui`）
4. 在 Test target 中右键 `agentGuiTests/` → `Add Files` → 选择所有新测试文件（target: `agentGuiTests`）：
   - `SessionMemoryStateTests.swift`
   - `SessionMemoryPromptBuilderTests.swift`
   - `SessionMemoryHookTests.swift`
   - `SessionMemoryServiceTests.swift`
   - `SessionMemoryPathTests.swift`

### Step 2: 确认完整构建

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 3: 运行所有 Session Memory 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m11-derived \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/SessionMemoryStateTests \
  -only-testing:agentGuiTests/SessionMemoryPromptBuilderTests \
  -only-testing:agentGuiTests/SessionMemoryHookTests \
  -only-testing:agentGuiTests/SessionMemoryServiceTests \
  -only-testing:agentGuiTests/SessionMemoryPathTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: 所有测试通过

### Step 4: Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(M-11): register new SessionMemory files in Xcode project"
```

---

## Task 11：Quality Smoke（全量测试验证）

### Step 1: 运行现有 Memory 相关测试确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m11-smoke \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  -only-testing:agentGuiTests/MemoryExtractionHookTests \
  -only-testing:agentGuiTests/MemoryExtractionCallbackTests \
  -only-testing:agentGuiTests/MemoryRecallHookTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`

### Step 2: 验证 `AgentLoopRunner` emit 不影响现有 Runner 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-m11-smoke2 \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

### Step 3: Final commit

```bash
git add -A
git commit -m "feat(M-11): session memory notes auto-update complete

- Add AgentLoopHookStage.willFinishRound + emit in AgentLoopRunner
- Add ConfigDirectoryManager.sessionMemoryDir/summaryURL
- Add SessionMemoryState actor (token + tool call threshold tracking)
- Add SessionMemoryPromptBuilder (10-section template, update prompt)
- Add SessionMemoryHook (willFinishRound, order=85, fire-and-forget)
- Add SessionMemoryService (subagent orchestration, file init/read)
- Add ClaudeService.buildSessionMemoryTools / sessionMemoryState(for:)
- Wire into AgentLoopBuiltInHookFactory + AgentLoopHookDependencyFactory

Aligns with Claude Code src/services/SessionMemory/ design.
SessionMemoryState persists across runCoreAgentLoop invocations per session.
Update subagent uses str_replace_based_edit_tool + read_file (FileEditTool pattern)."
```

---

## 验收标准

✓ 每次 `willFinishRound` 时 `SessionMemoryHook` 被触发  
✓ hook 只对 `.mainAgent` 执行上下文生效  
✓ token 估算达到 10,000 后初始化 `summary.md`  
✓ 此后每增长 5,000 tokens 且 ≥3 次工具调用时触发更新  
✓ 无工具调用的轮次如满足 token 增量也会触发（自然对话断点）  
✓ `summary.md` 路径：`~/.agentgui/sessions/{sessionId}/session-memory/summary.md`  
✓ 不覆盖已有 `summary.md`（首次创建时写入模板）  
✓ 提取过程不阻塞主对话（fire-and-forget）  
✓ 同一 session 中 `SessionMemoryState` 跨多次 `runCoreAgentLoop` 保持连续  
✓ 所有新增测试通过；现有内存相关测试无回归  

---

## 不在此计划范围内（后续 Feature）

- **M-12 Away Summary** — 基于 `summary.md` 生成会话恢复摘要
- **Context Compaction 集成** — `waitForSessionMemoryExtraction()` 在 compaction 前等待提取完成
- **`AppSettings.sessionMemoryEnabled`** — 用户可关闭 session memory 的设置 UI
- **`summary.md` → MemoryExtractionHook 辅助注入** — 提取 subagent 读取 `summary.md` 作为附加上下文
