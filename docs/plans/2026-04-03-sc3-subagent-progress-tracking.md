# S-C3 Subagent Progress Tracking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在每轮 API 响应后实时更新 `SubagentTaskRecord` 的进度字段（`toolUseCount`、`tokenCount`、`lastActivity`），让 UI 层和 S-C4 摘要服务能在后台子代理执行期间实时读取进度。

**Architecture:** 纯值类型 `SubagentProgressTracker` 存入 `AgentLoopRunState`，`@MainActor AgentLoopRoundExecutor.executeStreamingRound` 在每轮流式结束后调用 tracker mutating update（同步、无 IO、不阻塞 MainActor），然后调用注入在 `AgentLoopRuntime.subagentProgressUpdate` 中的回调写入 `SubagentTaskRecord`。进度回调标注 `@MainActor`，从 `@MainActor` 上下文直接调用，无需 `await`，无 UI 阻塞风险。

**Tech Stack:** Swift 6, SwiftData, SwiftAnthropic, `AgentLoopRoundExecutor`（`@MainActor`）, `SubagentBackgroundExecutor`（`actor`）, `AgentLoopRuntime`（struct）, `AgentLoopRunState`（struct）.

**参考来源:** Claude Code `src/tasks/LocalAgentTask/LocalAgentTask.tsx`（`ProgressTracker`、`updateProgressFromMessage`、`createProgressTracker`、`getProgressUpdate`）。

---

## ⚠️ Actor 隔离规则（Swift 6 强制）

1. **禁止** 在进度回调或 tracker 更新中 `await` 任何异步操作（保持 `executeStreamingRound` 流畅）。
2. **禁止** 在进度更新中调用 `modelContext.save()`（每轮调用会产生不必要的 IO；仅在 lifecycle 结束时 save）。
3. **所有** `SubagentTaskRecord` 字段写入必须在 `@MainActor` 上执行（SwiftData `@Model` 要求）；因为 `executeStreamingRound` 本身是 `@MainActor`，直接调用 `@MainActor` 回调时无需额外 hop。
4. `SubagentProgressTracker` 是 `struct`（值类型），存放在 `AgentLoopRunState`（也是 struct）中；mutating update 在 `@MainActor` 的 `executeStreamingRound` 中执行，无并发访问冲突。
5. `SubagentBackgroundExecutor` 是 `actor`，只负责生命周期管理；progress callback 创建后通过闭包传递给 `launchSubagent`，不在 actor 内部持有对 `SubagentTaskRecord` 的引用（避免跨 actor 访问 SwiftData 对象）。

---

## 文件清单

```
新增文件:
  agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift
  agentGuiTests/SubagentProgressTrackerTests.swift
  agentGuiTests/SubagentActivityClassifierTests.swift
  agentGuiTests/AgentLoopProgressCallbackTests.swift

修改文件:
  agentGui/Models/AgentLoopRuntime.swift
  agentGui/Models/AgentLoopRunState.swift
  agentGui/Services/AgentLoopRoundExecutor.swift
  agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
  agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
  agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift
  agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
```

---

## Task 1: 定义 `ToolActivity`、`SubagentProgress`、`SubagentProgressTracker`

**Files:**
- Create: `agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift`
- Test: `agentGuiTests/SubagentProgressTrackerTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/SubagentProgressTrackerTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class SubagentProgressTrackerTests: XCTestCase {

    // MARK: - ToolActivity

    func test_toolActivity_equatable() {
        let a = ToolActivity(toolName: "bash", activityDescription: "Running tests", isRead: false, isSearch: false)
        let b = ToolActivity(toolName: "bash", activityDescription: "Running tests", isRead: false, isSearch: false)
        XCTAssertEqual(a, b)
    }

    // MARK: - SubagentProgressTracker 初始状态

    func test_freshTracker_zerosAndEmpties() {
        let tracker = SubagentProgressTracker()
        XCTAssertEqual(tracker.toolUseCount, 0)
        XCTAssertEqual(tracker.tokenCount, 0)
        XCTAssertNil(tracker.lastActivity)
        XCTAssertTrue(tracker.recentActivities.isEmpty)
    }

    // MARK: - 输入 token 覆盖语义（最新值覆盖，不累加）

    func test_update_latestInputTokens_overridesPrevious() {
        var tracker = SubagentProgressTracker()
        // 第一轮：inputTokens=100
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 50),
            pendingTools: []
        )
        XCTAssertEqual(tracker.latestInputTokens, 100)

        // 第二轮：inputTokens=350（累计，Claude API 特性）→ 应覆盖而非累加
        tracker.update(
            usage: makeUsage(inputTokens: 350, outputTokens: 80),
            pendingTools: []
        )
        XCTAssertEqual(tracker.latestInputTokens, 350)
    }

    // MARK: - 输出 token 累加语义

    func test_update_cumulativeOutputTokens_accumulates() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: makeUsage(inputTokens: 100, outputTokens: 50), pendingTools: [])
        tracker.update(usage: makeUsage(inputTokens: 200, outputTokens: 80), pendingTools: [])
        XCTAssertEqual(tracker.cumulativeOutputTokens, 130)
    }

    // MARK: - tokenCount = latestInput + cumulativeOutput

    func test_tokenCount_computation() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: makeUsage(inputTokens: 300, outputTokens: 40), pendingTools: [])
        tracker.update(usage: makeUsage(inputTokens: 500, outputTokens: 60), pendingTools: [])
        // latestInput=500, cumulativeOutput=40+60=100
        XCTAssertEqual(tracker.tokenCount, 600)
    }

    // MARK: - cache token 计入 latestInputTokens

    func test_update_cacheTokens_countedInLatestInput() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 0, cacheCreation: 200, cacheRead: 50),
            pendingTools: []
        )
        // 100 + 200 + 50 = 350
        XCTAssertEqual(tracker.latestInputTokens, 350)
    }

    // MARK: - 工具计数

    func test_update_toolUseCount_incrementsPerTool() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 10),
            pendingTools: [
                makeToolStub(name: "bash", input: [:]),
                makeToolStub(name: "str_replace_based_edit_tool", input: ["command": "view", "path": "/foo.swift"])
            ]
        )
        XCTAssertEqual(tracker.toolUseCount, 2)
    }

    // MARK: - recentActivities 上限为 5

    func test_update_recentActivities_cappedAtFive() {
        var tracker = SubagentProgressTracker()
        for i in 0..<7 {
            tracker.update(
                usage: makeUsage(inputTokens: 100, outputTokens: 5),
                pendingTools: [makeToolStub(name: "bash", input: ["command": "echo \(i)"])]
            )
        }
        XCTAssertEqual(tracker.recentActivities.count, 5)
        XCTAssertEqual(tracker.toolUseCount, 7)   // count 不受 cap 影响
    }

    // MARK: - lastActivity = 最后一个工具

    func test_lastActivity_isLatestTool() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 100, outputTokens: 10),
            pendingTools: [
                makeToolStub(name: "bash", input: [:]),
                makeToolStub(name: "str_replace_based_edit_tool", input: ["command": "view", "path": "/bar.swift"])
            ]
        )
        XCTAssertEqual(tracker.lastActivity?.toolName, "str_replace_based_edit_tool")
    }

    // MARK: - nil usage 时仅更新工具（不崩溃）

    func test_update_nilUsage_onlyUpdateTools() {
        var tracker = SubagentProgressTracker()
        tracker.update(usage: nil, pendingTools: [makeToolStub(name: "bash", input: [:])])
        XCTAssertEqual(tracker.toolUseCount, 1)
        XCTAssertEqual(tracker.tokenCount, 0)
    }

    // MARK: - snapshot

    func test_snapshot_reflectsCurrentState() {
        var tracker = SubagentProgressTracker()
        tracker.update(
            usage: makeUsage(inputTokens: 200, outputTokens: 30),
            pendingTools: [makeToolStub(name: "bash", input: [:])]
        )
        let progress = tracker.snapshot()
        XCTAssertEqual(progress.toolUseCount, 1)
        XCTAssertEqual(progress.tokenCount, 230)
        XCTAssertNotNil(progress.lastActivity)
    }

    // MARK: - Helpers

    private func makeUsage(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0
    ) -> MessageResponse.Usage {
        MessageResponse.Usage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreation == 0 ? nil : cacheCreation,
            cacheReadInputTokens: cacheRead == 0 ? nil : cacheRead
        )
    }

    private func makeToolStub(name: String, input: [String: String]) -> AgentLoopPendingTool {
        var tool = AgentLoopPendingTool(id: UUID().uuidString, name: name)
        let jsonInput = try! JSONSerialization.data(withJSONObject: input)
        tool.partialJson = String(data: jsonInput, encoding: .utf8) ?? "{}"
        return tool
    }
}
```

### Step 2: 运行测试确认失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentProgressTrackerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|does not exist"
```

期望输出: 编译错误（`SubagentProgressTracker` 类型未定义）。

### Step 3: 实现 `SubagentProgressTracker.swift`

```swift
// agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift
import Foundation
import SwiftAnthropic

// MARK: - ToolActivity

/// 单次工具调用的轻量活动记录。
/// 对应 Claude Code `LocalAgentTask.tsx` 的 `ToolActivity` 类型。
struct ToolActivity: Sendable, Equatable, Codable {
    /// 工具 ID，例如 "str_replace_based_edit_tool"
    var toolName: String
    /// 人类可读描述，例如 "Reading ClaudeService.swift"（nil = 未知）
    var activityDescription: String?
    /// 是否为只读操作（view、read_tool_payload、LSP query 等）
    var isRead: Bool
    /// 是否为搜索操作（web_search、bash grep 等）
    var isSearch: Bool
}

// MARK: - SubagentProgress

/// 某时刻的进度快照（不可变，供 UI / S-C4 读取）。
struct SubagentProgress: Sendable {
    var toolUseCount: Int
    var tokenCount: Int
    var recentActivities: [ToolActivity]
    var lastActivity: ToolActivity?
    /// 由 S-C4 SubagentProgressSummarizer 填充的短语（"Reading ClaudeService.swift"）
    var progressSummary: String?
}

// MARK: - SubagentProgressTracker

/// 跨轮次累积的可变进度追踪器。
///
/// **Token 计数语义（与 Claude Code 保持一致）：**
/// - `latestInputTokens` — Claude API 的 `input_tokens` 是每轮**累计**值（含所有历史 context），
///   因此只保存最新值，不累加。公式：
///   `latestInputTokens = inputTokens + cacheCreationInputTokens + cacheReadInputTokens`
/// - `cumulativeOutputTokens` — 每轮独立产出，显式累加。
/// - `tokenCount` = `latestInputTokens + cumulativeOutputTokens`
///
/// **线程安全：** 值类型（struct），存储于 `@MainActor` 的 `AgentLoopRunState` 中。
/// 所有 mutating 操作必须在 `@MainActor` 上调用（`AgentLoopRoundExecutor` 保证）。
struct SubagentProgressTracker: Sendable {

    // MARK: - State

    private(set) var toolUseCount: Int = 0
    private(set) var latestInputTokens: Int = 0
    private(set) var cumulativeOutputTokens: Int = 0
    private(set) var recentActivities: [ToolActivity] = []

    static let maxRecentActivities = 5

    // MARK: - Computed

    var tokenCount: Int { latestInputTokens + cumulativeOutputTokens }
    var lastActivity: ToolActivity? { recentActivities.last }

    // MARK: - Update

    /// 消费一轮 API 响应的 usage + pendingTools，原地更新追踪器状态。
    ///
    /// - Parameters:
    ///   - usage: 该轮 API 响应的 token 用量（nil = API 未返回，安全忽略）
    ///   - pendingTools: 该轮 assistant 消息中解析出的工具调用块
    mutating func update(
        usage: MessageResponse.Usage?,
        pendingTools: [AgentLoopPendingTool]
    ) {
        // 更新 token 计数
        if let usage {
            latestInputTokens = (usage.inputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0)
            cumulativeOutputTokens += usage.outputTokens
        }

        // 更新工具活动
        let classifier = SubagentActivityClassifier()
        for tool in pendingTools {
            toolUseCount += 1
            let activity = classifier.classify(toolName: tool.name, input: tool.parsedInput)
            recentActivities.append(activity)
        }

        // 保持 recentActivities 上限
        while recentActivities.count > Self.maxRecentActivities {
            recentActivities.removeFirst()
        }
    }

    // MARK: - Snapshot

    /// 返回当前状态的不可变快照。
    func snapshot(progressSummary: String? = nil) -> SubagentProgress {
        SubagentProgress(
            toolUseCount: toolUseCount,
            tokenCount: tokenCount,
            recentActivities: recentActivities,
            lastActivity: lastActivity,
            progressSummary: progressSummary
        )
    }
}

// MARK: - SubagentActivityClassifier

/// 将工具名称 + 输入映射为可读 `ToolActivity`。
///
/// 对应 Claude Code `createActivityDescriptionResolver` +
/// 各工具的 `getActivityDescription` 方法。
/// 此处使用独立分类器（不修改 `ToolDefinition`），保持 S-C3 最小侵入性。
struct SubagentActivityClassifier: Sendable {

    func classify(
        toolName: String,
        input: MessageResponse.Content.Input
    ) -> ToolActivity {
        switch toolName {

        case "str_replace_based_edit_tool":
            let command = input["command"]?.stringValue ?? "view"
            let path = input["path"]?.stringValue.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            switch command {
            case "view":
                let desc = path.isEmpty ? "Reading file" : "Reading \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: true, isSearch: false)
            case "str_replace":
                let desc = path.isEmpty ? "Editing file" : "Editing \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            case "create":
                let desc = path.isEmpty ? "Creating file" : "Creating \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            case "insert":
                let desc = path.isEmpty ? "Inserting in file" : "Inserting in \(path)"
                return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: false)
            default:
                return ToolActivity(toolName: toolName, activityDescription: "Using editor", isRead: false, isSearch: false)
            }

        case "bash":
            let command = input["command"]?.stringValue ?? ""
            let preview = command.isEmpty ? "Running command" : "Running: \(String(command.prefix(40)))"
            // grep / rg / find 模式视为 search
            let isSearch = command.hasPrefix("grep") || command.hasPrefix("rg ") || command.hasPrefix("find ")
            return ToolActivity(toolName: toolName, activityDescription: preview, isRead: false, isSearch: isSearch)

        case "web_search", "web_search_brave":
            let query = input["query"]?.stringValue ?? ""
            let desc = query.isEmpty ? "Searching web" : "Searching for \(String(query.prefix(40)))"
            return ToolActivity(toolName: toolName, activityDescription: desc, isRead: false, isSearch: true)

        case "web_fetch":
            let url = input["url"]?.stringValue ?? ""
            let preview = url.isEmpty ? "Fetching URL" : "Fetching \(String(url.prefix(50)))"
            return ToolActivity(toolName: toolName, activityDescription: preview, isRead: true, isSearch: false)

        case "read_tool_payload":
            return ToolActivity(toolName: toolName, activityDescription: "Reading payload", isRead: true, isSearch: false)

        case let lsp where lsp.hasPrefix("lsp_"):
            let pretty = lsp.replacingOccurrences(of: "lsp_", with: "").replacingOccurrences(of: "_", with: " ")
            return ToolActivity(toolName: toolName, activityDescription: "LSP: \(pretty)", isRead: true, isSearch: false)

        case "run_subagent":
            let name = input["agent_name"]?.stringValue ?? "subagent"
            return ToolActivity(toolName: toolName, activityDescription: "Launching \(name)", isRead: false, isSearch: false)

        default:
            return ToolActivity(toolName: toolName, activityDescription: nil, isRead: false, isSearch: false)
        }
    }
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentProgressTrackerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望: 所有测试 PASS。

### Step 5: Commit

```bash
git add agentGui/Services/SubagentGovernance/SubagentProgressTracker.swift \
        agentGuiTests/SubagentProgressTrackerTests.swift
git commit -m "feat(S-C3): add SubagentProgressTracker, ToolActivity, SubagentActivityClassifier"
```

---

## Task 2: `SubagentActivityClassifier` 专项测试

**Files:**
- Test: `agentGuiTests/SubagentActivityClassifierTests.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/SubagentActivityClassifierTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

final class SubagentActivityClassifierTests: XCTestCase {
    let classifier = SubagentActivityClassifier()

    // MARK: - str_replace_based_edit_tool

    func test_editor_view_isRead() {
        let input: MessageResponse.Content.Input = [
            "command": .string("view"),
            "path": .string("/Users/dev/Project/ClaudeService.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertFalse(activity.isSearch)
        XCTAssertEqual(activity.activityDescription, "Reading ClaudeService.swift")
    }

    func test_editor_strReplace_isNotRead() {
        let input: MessageResponse.Content.Input = [
            "command": .string("str_replace"),
            "path": .string("/Foo/Bar.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertFalse(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Editing Bar.swift")
    }

    func test_editor_create_description() {
        let input: MessageResponse.Content.Input = [
            "command": .string("create"),
            "path": .string("/Foo/New.swift")
        ]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertEqual(activity.activityDescription, "Creating New.swift")
    }

    func test_editor_noPath_fallback() {
        let input: MessageResponse.Content.Input = ["command": .string("view")]
        let activity = classifier.classify(toolName: "str_replace_based_edit_tool", input: input)
        XCTAssertEqual(activity.activityDescription, "Reading file")
    }

    // MARK: - bash

    func test_bash_normalCommand() {
        let input: MessageResponse.Content.Input = [
            "command": .string("swift test 2>&1")
        ]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertFalse(activity.isRead)
        XCTAssertFalse(activity.isSearch)
        XCTAssertTrue(activity.activityDescription?.hasPrefix("Running:") == true)
    }

    func test_bash_grepIsSearch() {
        let input: MessageResponse.Content.Input = [
            "command": .string("grep -rn 'SubagentTaskRecord' .")
        ]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertTrue(activity.isSearch)
    }

    func test_bash_emptyCommand_fallback() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "bash", input: input)
        XCTAssertEqual(activity.activityDescription, "Running command")
    }

    // MARK: - web_search

    func test_webSearch_isSearch() {
        let input: MessageResponse.Content.Input = ["query": .string("Swift actor isolation")]
        let activity = classifier.classify(toolName: "web_search", input: input)
        XCTAssertTrue(activity.isSearch)
        XCTAssertFalse(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Searching for Swift actor isolation")
    }

    func test_webSearchBrave_isSearch() {
        let input: MessageResponse.Content.Input = ["query": .string("SwiftData performance")]
        let activity = classifier.classify(toolName: "web_search_brave", input: input)
        XCTAssertTrue(activity.isSearch)
    }

    // MARK: - web_fetch

    func test_webFetch_isRead() {
        let input: MessageResponse.Content.Input = ["url": .string("https://example.com/docs")]
        let activity = classifier.classify(toolName: "web_fetch", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertFalse(activity.isSearch)
    }

    // MARK: - read_tool_payload

    func test_readToolPayload_isRead() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "read_tool_payload", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertEqual(activity.activityDescription, "Reading payload")
    }

    // MARK: - LSP tools

    func test_lspTool_isRead() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "lsp_definition", input: input)
        XCTAssertTrue(activity.isRead)
        XCTAssertTrue(activity.activityDescription?.hasPrefix("LSP:") == true)
    }

    // MARK: - run_subagent

    func test_runSubagent_description() {
        let input: MessageResponse.Content.Input = ["agent_name": .string("explore")]
        let activity = classifier.classify(toolName: "run_subagent", input: input)
        XCTAssertEqual(activity.activityDescription, "Launching explore")
    }

    // MARK: - unknown tool fallback

    func test_unknownTool_nilDescription() {
        let input: MessageResponse.Content.Input = [:]
        let activity = classifier.classify(toolName: "some_unknown_tool_xyz", input: input)
        XCTAssertNil(activity.activityDescription)
        XCTAssertFalse(activity.isRead)
        XCTAssertFalse(activity.isSearch)
    }
}
```

### Step 2: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentActivityClassifierTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望: 所有测试 PASS。

### Step 3: Commit

```bash
git add agentGuiTests/SubagentActivityClassifierTests.swift
git commit -m "test(S-C3): add SubagentActivityClassifier tests"
```

---

## Task 3: `AgentLoopRuntime` 新增 `subagentProgressUpdate` 回调

**Files:**
- Modify: `agentGui/Models/AgentLoopRuntime.swift`

### Step 1: 修改 `AgentLoopRuntime`

在 `AgentLoopRuntime.swift` 中添加新属性和初始化参数：

```swift
// 在现有属性下方添加（位于 remoteDeliveryHandle 之后）:
/// S-C3: 子代理进度回调（nil = 主代理 loop，不追踪进度）。
/// 每轮 API 响应结束后由 `AgentLoopRoundExecutor.executeStreamingRound` 调用。
/// 标注 `@MainActor` 保证 SwiftData `@Model` 字段写入在主线程，且调用时无需 `await`。
let subagentProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)?
```

在 `init` 参数列表末尾添加：
```swift
subagentProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil
```

在 `init` 体中添加：
```swift
self.subagentProgressUpdate = subagentProgressUpdate
```

> **向后兼容：** 参数默认值 `= nil`，所有现有调用方无需修改。

### Step 2: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望: `Build succeeded`（无编译错误）。

### Step 3: Commit

```bash
git add agentGui/Models/AgentLoopRuntime.swift
git commit -m "feat(S-C3): add subagentProgressUpdate callback to AgentLoopRuntime"
```

---

## Task 4: `AgentLoopRunState` 新增 `subagentProgressTracker`

**Files:**
- Modify: `agentGui/Models/AgentLoopRunState.swift`

### Step 1: 修改 `AgentLoopRunState`

在现有属性下方（`bootstrapSystemAppend` 之后）添加：

```swift
/// S-C3: 子代理进度追踪器（nil = 非子代理 run）。
/// 由 `runCoreAgentLoop` 在检测到 `runtime.subagentProgressUpdate != nil` 时初始化。
var subagentProgressTracker: SubagentProgressTracker?
```

在 `init` 末尾添加初始化参数（默认 nil）：
```swift
subagentProgressTracker: SubagentProgressTracker? = nil
```

```swift
self.subagentProgressTracker = subagentProgressTracker
```

> **向后兼容：** 默认值 `nil`，现有 `AgentLoopRunState()` 调用均无需修改。

### Step 2: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 3: Commit

```bash
git add agentGui/Models/AgentLoopRunState.swift
git commit -m "feat(S-C3): add subagentProgressTracker to AgentLoopRunState"
```

---

## Task 5: `runCoreAgentLoop` 初始化 tracker

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

### Step 1: 在 `runCoreAgentLoop` 中初始化 tracker

定位 `let initialState = AgentLoopRunState()` 这一行（约第 191 行），在其后添加 S-C3 注释块：

```swift
let initialState = AgentLoopRunState()

// S-C3: 当 runtime 携带进度回调时，说明本次 loop 以子代理身份运行，初始化进度追踪器
if runtime.subagentProgressUpdate != nil {
    initialState.subagentProgressTracker = SubagentProgressTracker()
}
```

> **注意：** `AgentLoopRunState` 是 `struct`（值类型），`initialState` 是 `var`。修改需要将 `let initialState` 改为 `var initialState`（若原来是 `let`）。

### Step 2: 编译验证（含 struct mutability 修复）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

若报 `cannot assign to value: 'initialState' is a 'let' constant`，将声明改为 `var initialState`。

### Step 3: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "feat(S-C3): init subagentProgressTracker in runCoreAgentLoop when callback present"
```

---

## Task 6: `AgentLoopRoundExecutor` 触发进度更新

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

### Step 1: 写失败测试

```swift
// agentGuiTests/AgentLoopProgressCallbackTests.swift
import XCTest
import SwiftAnthropic
@testable import agentGui

/// 验证 executeStreamingRound 结束后进度回调被调用且字段正确。
/// 使用已有 AgentLoopRoundExecutor 测试基础设施（参考 AgentLoopRoundStreamAssemblerUsageTests）。
final class AgentLoopProgressCallbackTests: XCTestCase {

    func test_progressCallback_calledAfterRound_withCorrectToolCount() async throws {
        // Given: 构造一个带进度回调的 runtime
        var capturedProgress: SubagentProgress?
        let progressCallback: @MainActor @Sendable (SubagentProgress) -> Void = { progress in
            capturedProgress = progress
        }

        // 使用测试用的 mock runtime（子代理运行上下文）
        let runtime = makeSubagentRuntime(progressCallback: progressCallback)

        // When: 执行一轮包含工具调用的 mock stream
        // （此处依赖 AgentLoopRoundExecutorTestFixtures 或等效 mock 基础设施）
        // TODO: 实现细节见 Step 3

        // Then:
        XCTAssertNotNil(capturedProgress)
        XCTAssertGreaterThan(capturedProgress?.toolUseCount ?? 0, 0)
    }

    func test_nilProgressCallback_doesNotCrash() async throws {
        // 主代理 runtime（无回调）运行不崩溃
        let runtime = makeSubagentRuntime(progressCallback: nil)
        XCTAssertNil(runtime.subagentProgressUpdate)
    }

    // MARK: - Helpers

    @MainActor private func makeSubagentRuntime(
        progressCallback: (@MainActor @Sendable (SubagentProgress) -> Void)?
    ) -> AgentLoopRuntime {
        let settings = AppSettings()
        return AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: UUID().uuidString,
            modelContext: try! makeInMemoryContainer().mainContext,
            makeRound: { idx in AgentRound(roundIndex: idx) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil,
            subagentProgressUpdate: progressCallback
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([AgentRound.self, Message.self, Session.self, ToolCall.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
```

### Step 2: 运行测试（部分失败预期）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/AgentLoopProgressCallbackTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|PASS|FAIL"
```

期望: `test_nilProgressCallback_doesNotCrash` PASS，`test_progressCallback_calledAfterRound_withCorrectToolCount` 因 TODO 跳过或 FAIL。

### Step 3: 在 `executeStreamingRound` 中插入进度更新

在 `executeStreamingRound` 方法内，找到 `return RoundOutcome(` 之前（约在处理完 `pendingTools` 和 `stopReason` 之后）插入：

```swift
// S-C3: 子代理进度追踪 —— 轻量同步更新，不 await，不阻塞 MainActor
// 必须在 RoundOutcome 返回前执行，确保每轮数据被记录
if state.subagentProgressTracker != nil {
    state.subagentProgressTracker!.update(
        usage: streamSnapshot.usage,
        pendingTools: pendingTools
    )
    // 调用进度回调（@MainActor，直接调用无需 await）
    runtime.subagentProgressUpdate?(state.subagentProgressTracker!.snapshot())
}
```

**精确插入位置**（在 `return RoundOutcome(...)` 的前两行）：

找到 `AgentLoopRoundExecutor.swift` 中的以下片段（约在 `executeStreamingRound` 末尾）：

```swift
        roundSpan.addMetadata("stopReason", value: stopReason ?? "nil")
        roundSpan.addMetadata("phase", value: state.loopCtx.phase.label)
        roundSpan.addMetadata("textBytes", value: currentRoundText.count)

        await recordEpistemicInputEnvelope(
```

在 `recordEpistemicInputEnvelope` 调用之后、`return RoundOutcome(` 之前插入 S-C3 代码块：

```swift
        // S-C3: 更新子代理进度追踪器（仅子代理 run，同步无 IO）
        if state.subagentProgressTracker != nil {
            state.subagentProgressTracker!.update(
                usage: streamSnapshot.usage,
                pendingTools: pendingTools
            )
            runtime.subagentProgressUpdate?(state.subagentProgressTracker!.snapshot())
        }

        return RoundOutcome(
```

### Step 4: 运行全部进度测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentProgressTrackerTests \
  -only-testing:agentGuiTests/SubagentActivityClassifierTests \
  -only-testing:agentGuiTests/AgentLoopProgressCallbackTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

期望: 所有可运行测试 PASS，无编译错误。

### Step 5: Commit

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift \
        agentGuiTests/AgentLoopProgressCallbackTests.swift
git commit -m "feat(S-C3): trigger progress update in executeStreamingRound"
```

---

## Task 7: `ClaudeService+Subagent` 接收并传递 `onProgressUpdate`

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

> **说明：** `runSubagentLoop` 需要新增可选的 `onProgressUpdate` 参数；现有 14 个调用方无需修改（参数有默认值 `nil`）。

### Step 1: 修改 `runSubagentLoop` 签名

在 `runSubagentLoop` 的方法签名中，在 `modelContext: ModelContext` 之后添加：

```swift
onProgressUpdate: (@MainActor @Sendable (SubagentProgress) -> Void)? = nil
```

### Step 2: 修改 `AgentLoopRuntime` 构建调用

找到 `runSubagentLoop` 内 `let runtime = AgentLoopRuntime(` 的构造调用，在 `toolInterceptor: nil` 之后添加：

```swift
subagentProgressUpdate: onProgressUpdate
```

完整的 runtime 构建应为：

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
    subagentProgressUpdate: onProgressUpdate  // S-C3
)
```

### Step 3: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 4: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(S-C3): thread onProgressUpdate through runSubagentLoop"
```

---

## Task 8: 更新 `SubagentLaunchClosure` 和 `SubagentBackgroundExecutor`

**Files:**
- Modify: `agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift`

这是 S-C3 的关键接线任务：在后台执行路径中，创建写入 `SubagentTaskRecord` 的进度回调，并通过更新的 `SubagentLaunchClosure` 传递给 `runSubagentLoop`。

### Step 1: 更新 `SubagentLaunchClosure` 类型

将现有 typealias 从：
```swift
typealias SubagentLaunchClosure = @MainActor (String, WorkflowRoleDefinition) async -> SubagentLaunchResult
```

改为：
```swift
typealias SubagentLaunchClosure = @MainActor (
    _ task: String,
    _ definition: WorkflowRoleDefinition,
    _ progressCallback: (@MainActor @Sendable (SubagentProgress) -> Void)?
) async -> SubagentLaunchResult
```

### Step 2: 更新 `SubagentBackgroundExecutor.launch` 同步路径

找到同步路径（`guard params.runInBackground else` 块），更新调用：

```swift
guard params.runInBackground else {
    let result = await params.launchSubagent(params.task, params.definition, nil)
    return result
}
```

### Step 3: 更新 `runBackgroundLifecycle` 创建并传递进度回调

在 `runBackgroundLifecycle` 方法内，`let result = await params.launchSubagent(...)` 调用前，添加：

```swift
// S-C3: 构建进度回调，将 SubagentProgress 写入已持久化的 SubagentTaskRecord
// 注意：回调标注 @MainActor，由 AgentLoopRoundExecutor（@MainActor）直接调用，无需 await。
// 不在此处调用 modelContext.save()，避免每轮 IO；save 在 finalize 时统一执行。
let progressCallback: @MainActor @Sendable (SubagentProgress) -> Void = { [record] progress in
    record.toolUseCount = progress.toolUseCount
    record.tokenCount = progress.tokenCount
    record.lastActivity = progress.lastActivity?.activityDescription
}

let result = await params.launchSubagent(params.task, params.definition, progressCallback)
```

### Step 4: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

若出现 `@MainActor` 隔离相关错误（Swift 6 严格），确认：
- `progressCallback` 闭包体内对 `record` 的访问在 `@MainActor` 上下文（闭包已标注 `@MainActor`，合法）。
- `record` 是 `SubagentTaskRecord`（SwiftData `@Model`），在 `@MainActor` 上访问合规。

### Step 5: Commit

```bash
git add agentGui/Services/SubagentGovernance/SubagentBackgroundExecutor.swift
git commit -m "feat(S-C3): wire progress callback through SubagentLaunchClosure lifecycle"
```

---

## Task 9: 更新 `AgentLoopToolExecutionCoordinatorBuilder`

**Files:**
- Modify: `agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

这是 Task 8 的必要配套修改：更新 `launchSubagent` 闭包签名，将收到的 `progressCallback` 传递给 `runSubagentLoop`。

### Step 1: 更新 `launchSubagent` 闭包

找到 `AgentLoopToolExecutionCoordinatorBuilder.build()` 内的 `launchSubagent:` 参数，将闭包签名从：

```swift
launchSubagent: { [claudeService, service, modelId, settings] input, record, definitionResolver, backgroundExecutor, ctx in
```

... 内部的：

```swift
launchSubagent: { task, def in
    do {
        return try await .sync(message: claudeService.runSubagentLoop(
            task: task,
            definition: def,
            toolCallRecord: record,
            service: service,
            modelId: modelId,
            overrideModelId: overrideModelId,
            settings: settings,
            sessionId: capturedSessionId,
            modelContext: capturedModelContext
        ))
    } catch {
        return .sync(message: .error(error.localizedDescription, sender: def.name))
    }
}
```

改为：

```swift
launchSubagent: { task, def, progressCallback in
    do {
        return try await .sync(message: claudeService.runSubagentLoop(
            task: task,
            definition: def,
            toolCallRecord: record,
            service: service,
            modelId: modelId,
            overrideModelId: overrideModelId,
            settings: settings,
            sessionId: capturedSessionId,
            modelContext: capturedModelContext,
            onProgressUpdate: progressCallback  // S-C3
        ))
    } catch {
        return .sync(message: .error(error.localizedDescription, sender: def.name))
    }
}
```

同样，非后台同步路径（如果存在独立的同步 `runSubagentLoop` 调用）也需要在末尾添加 `onProgressUpdate: nil`。

### Step 2: 编译验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

### Step 3: Commit

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift
git commit -m "feat(S-C3): pass progressCallback through launchSubagent closure in coordinator builder"
```

---

## Task 10: 全量测试验证

### Step 1: 运行 S-C3 专项测试套件

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentProgressTrackerTests \
  -only-testing:agentGuiTests/SubagentActivityClassifierTests \
  -only-testing:agentGuiTests/AgentLoopProgressCallbackTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望: 所有测试 PASS，0 failures。

### Step 2: 运行回归测试（S-C2 相关）

验证对 `SubagentBackgroundExecutor` 的修改没有破坏已有 S-C2 测试：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/SubagentBackgroundExecutorTests \
  -only-testing:agentGuiTests/SubagentCoordinatorIntegrationTests \
  -only-testing:agentGuiTests/SubagentTaskRecordTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望: 所有测试 PASS。

### Step 3: 运行 AgentLoop 核心回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sc3-progress-derived \
  -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerUsageTests \
  -only-testing:agentGuiTests/AgentLoopRoundExecutorWillStartRoundPatchTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望: 所有测试 PASS（验证 `executeStreamingRound` 修改无副作用）。

### Step 4: 最终 Commit

```bash
git commit --allow-empty -m "feat(S-C3): subagent progress tracking complete

- SubagentProgressTracker: 跨轮次 token/tool 累积追踪器
- SubagentActivityClassifier: 工具活动描述生成器
- AgentLoopRuntime.subagentProgressUpdate: @MainActor 回调注入点
- AgentLoopRunState.subagentProgressTracker: 可选追踪器字段
- executeStreamingRound: 每轮流式结束后同步更新进度（无 IO，不阻塞 MainActor）
- SubagentLaunchClosure: 新增 progressCallback 参数
- SubagentBackgroundExecutor: 后台 lifecycle 中创建写 SubagentTaskRecord 的回调
- AgentLoopToolExecutionCoordinatorBuilder: launchSubagent 闭包传递 progressCallback

对应设计文档: docs/plans/2026-04-01-subagent-capability-enhancement-design.md S-C3"
```

---

## 常见问题排查

| 症状 | 原因 | 修复 |
|------|------|------|
| `cannot assign to value: 'initialState' is a 'let' constant` | `runCoreAgentLoop` 中 `initialState` 声明为 `let` | 改为 `var initialState` |
| `@MainActor` 相关隔离错误 | `progressCallback` 闭包未正确标注 | 确认 `@MainActor @Sendable` 双修饰 |
| `SubagentLaunchClosure` 参数数量不匹配编译错误 | 闭包调用或定义漏了 `progressCallback` 参数 | 检查所有 3 个调用点（同步路径 nil、后台路径传 progressCallback）|
| 测试中 `MessageResponse.Usage` 无公开 init | SwiftAnthropic 封装问题 | 使用 `JSONDecoder` 从 stub JSON 解码，或用 `@testable` 暴露 internal init |
| `AgentLoopPendingTool.partialJson` 无法在测试中构造 | 类型定义未暴露 `partialJson` | 在 `AgentLoopRoundStreamAssembler.swift` 确认 `partialJson` 是 `var`（已有），使用 `makeToolStub` helper |

---

## 验收标准对照

| 设计文档要求 | 实现位置 | 验证方式 |
|-------------|---------|---------|
| `toolUseCount` 每轮累计 | `SubagentProgressTracker.update` | `SubagentProgressTrackerTests.test_update_toolUseCount_incrementsPerTool` |
| `tokenCount = latestInput + cumulativeOutput` | `SubagentProgressTracker.tokenCount` | `SubagentProgressTrackerTests.test_tokenCount_computation` |
| `lastActivity` 更新为最近工具 | `SubagentProgressTracker.lastActivity` | `SubagentProgressTrackerTests.test_lastActivity_isLatestTool` |
| 进度更新不阻塞子代理 loop | `@MainActor` 同步调用，无 IO | 代码审查：无 `await`，无 `save()` |
| `SubagentTaskRecord` 字段实时可读 | `progressCallback` 写入 `record` 字段 | `AgentLoopProgressCallbackTests` |
| 后台模式可观察（S-C4/S-I1 接入点） | `SubagentProgress.progressSummary` 字段预留 | 类型定义完整 |
