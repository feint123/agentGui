# S-C1 SubagentTaskRecord SwiftData 模型实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `SubagentTaskRecord` SwiftData `@Model`，作为后台子代理执行的持久化任务记录，为 S-C2（异步后台执行器）、S-C3（进度追踪）和 S-I1（UI Panel）提供数据基础。

**Architecture:** 仿照 `AgentTeamSessionState` 的 rawValue 存储模式，枚举字段以 `statusRaw: String` 持久化、计算属性提供强类型访问；模型注册到 `PersistenceSchema.sharedModelTypes`；`SubagentTaskStatus` 枚举单独定义在同一文件，此阶段不建立与 `ToolCall`／`Session` 的 SwiftData `@Relationship`（保留 ID 引用，关系由 S-C2 按需添加，避免迁移复杂度）。

**Tech Stack:** Swift 6, SwiftData, XCTest（in-memory ModelContainer 测试模式）。

**依赖状态:** 无前置 Feature 依赖，可独立落地。

---

## 参考：Claude Code LocalAgentTask 对应字段

`src/tasks/LocalAgentTask/LocalAgentTask.tsx` 中 `LocalAgentTaskState` 的对应关系：

| Claude Code 字段 | SubagentTaskRecord 字段 | 说明 |
|-----------------|------------------------|------|
| `agentId` | `id` | UUID 主键 |
| `agentType` | `agentName` | 代理类型名，如 "verifier" |
| `prompt` | `task` | 原始任务入参 |
| `progress.toolUseCount` | `toolUseCount` | 累计工具调用次数 |
| `progress.tokenCount` | `tokenCount` | 累计 token 消耗 |
| `progress.lastActivity?.activityDescription` | `lastActivity` | 最近活动描述 |
| `progress.summary` | `progressSummary` | S-C4 30s 摘要 |
| `result` | `result` | 最终输出文本 |
| `error` | `errorMessage` | 错误信息 |
| `evictAfter` → running/completed/failed/cancelled | `statusRaw` | 任务状态机 |

---

## 现状缺口

| 层面 | 状态 |
|------|------|
| `SubagentTaskRecord` 模型文件 | ❌ 不存在，需新建 |
| `SubagentTaskStatus` 枚举 | ❌ 不存在，需在同文件定义 |
| 注册到 `PersistenceSchema.sharedModelTypes` | ❌ 未注册 |
| 单元测试 | ❌ 需新建 |

---

## 文件清单

| 操作 | 文件路径 |
|------|---------|
| **新建** | `agentGui/Models/SubagentTaskRecord.swift` |
| **新建** | `agentGuiTests/SubagentTaskRecordTests.swift` |
| **修改** | `agentGui/agentGuiApp.swift`（注册到 `PersistenceSchema.sharedModelTypes`）|

---

## Task 1：编写失败测试

**Files:**
- Create: `agentGuiTests/SubagentTaskRecordTests.swift`

### Step 1: 新建测试文件（此时 SubagentTaskRecord 不存在，编译会失败）

```swift
// agentGuiTests/SubagentTaskRecordTests.swift
import XCTest
import SwiftData
@testable import agentGui

final class SubagentTaskRecordTests: XCTestCase {

    // MARK: - 辅助

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([SubagentTaskRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 初始化默认值测试

    func test_init_defaultStatus_isPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            description: "运行测试套件",
            task: "Run the full test suite and report results."
        )
        XCTAssertEqual(record.status, .pending)
    }

    func test_init_toolUseCount_isZero() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "explore",
            description: "探索代码库",
            task: "Find all usages of ClaudeService."
        )
        XCTAssertEqual(record.toolUseCount, 0)
        XCTAssertEqual(record.tokenCount, 0)
    }

    func test_init_optionalFields_areNil() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "worker",
            description: "修改文件",
            task: "Refactor the login flow."
        )
        XCTAssertNil(record.modelID)
        XCTAssertNil(record.completedAt)
        XCTAssertNil(record.result)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(record.lastActivity)
        XCTAssertNil(record.progressSummary)
        XCTAssertNil(record.transcriptPath)
    }

    // MARK: - status 计算属性测试

    func test_statusRoundTrip_allCases() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            description: "验证",
            task: "Verify the fix."
        )

        for caseValue in SubagentTaskStatus.allCases {
            record.status = caseValue
            XCTAssertEqual(record.status, caseValue,
                "状态 \(caseValue) 经 rawValue 往返后应保持一致")
        }
    }

    func test_statusRaw_defaultValue_isPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            description: "验证",
            task: "Verify the fix."
        )
        XCTAssertEqual(record.statusRaw, SubagentTaskStatus.pending.rawValue)
    }

    func test_status_unknownRaw_fallsBackToPending() {
        let record = SubagentTaskRecord(
            sessionID: UUID(),
            parentToolCallID: UUID(),
            agentName: "verifier",
            description: "验证",
            task: "Verify the fix."
        )
        record.statusRaw = "unknown_future_value"
        XCTAssertEqual(record.status, .pending,
            "未知 rawValue 应 fallback 到 .pending")
    }

    // MARK: - SwiftData 持久化测试

    func test_persistAndFetch_roundTripsAllFields() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let toolCallID = UUID()

        let record = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: toolCallID,
            agentName: "verifier",
            description: "运行集成测试",
            task: "Run ConversationExecutionRuntimeCoordinatorTests and report verdict.",
            modelID: "claude-sonnet-4-6"
        )
        record.status = .running
        record.toolUseCount = 12
        record.tokenCount = 4800
        record.lastActivity = "Running xcodebuild test"
        record.progressSummary = "Running integration tests"

        context.insert(record)
        try context.save()

        var descriptor = FetchDescriptor<SubagentTaskRecord>()
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 1)
        let r = fetched[0]
        XCTAssertEqual(r.sessionID, sessionID)
        XCTAssertEqual(r.parentToolCallID, toolCallID)
        XCTAssertEqual(r.agentName, "verifier")
        XCTAssertEqual(r.description, "运行集成测试")
        XCTAssertEqual(r.task, "Run ConversationExecutionRuntimeCoordinatorTests and report verdict.")
        XCTAssertEqual(r.modelID, "claude-sonnet-4-6")
        XCTAssertEqual(r.status, .running)
        XCTAssertEqual(r.toolUseCount, 12)
        XCTAssertEqual(r.tokenCount, 4800)
        XCTAssertEqual(r.lastActivity, "Running xcodebuild test")
        XCTAssertEqual(r.progressSummary, "Running integration tests")
    }

    func test_persistAndFetch_multipleRecords_sameSession() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()

        let r1 = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: UUID(),
            agentName: "explore",
            description: "探索代码库",
            task: "Find ClaudeService usages."
        )
        let r2 = SubagentTaskRecord(
            sessionID: sessionID,
            parentToolCallID: UUID(),
            agentName: "verifier",
            description: "验证修复",
            task: "Run tests."
        )
        r1.status = .completed
        r2.status = .running

        context.insert(r1)
        context.insert(r2)
        try context.save()

        var descriptor = FetchDescriptor<SubagentTaskRecord>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        descriptor.sortBy = [SortDescriptor(\SubagentTaskRecord.startedAt)]
        let fetched = try context.fetch(descriptor)

        XCTAssertEqual(fetched.count, 2)
        let names = fetched.map(\.agentName)
        XCTAssertTrue(names.contains("explore"))
        XCTAssertTrue(names.contains("verifier"))
    }

    // MARK: - SubagentTaskStatus allCases 覆盖

    func test_allStatusCases_haveDistinctRawValues() {
        let rawValues = SubagentTaskStatus.allCases.map(\.rawValue)
        let uniqueRawValues = Set(rawValues)
        XCTAssertEqual(rawValues.count, uniqueRawValues.count,
            "所有状态的 rawValue 必须唯一")
    }

    func test_allStatusCases_nonEmpty() {
        XCTAssertFalse(SubagentTaskStatus.allCases.isEmpty)
    }
}
```

### Step 2: 确认测试无法编译

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|SubagentTaskRecord" | head -10
```

期望：编译错误，提示 `SubagentTaskRecord` 和 `SubagentTaskStatus` 未定义。

### Step 3: 提交占位测试

```bash
git add agentGuiTests/SubagentTaskRecordTests.swift
git commit -m "test(s-c1): add failing tests for SubagentTaskRecord"
```

---

## Task 2：实现 SubagentTaskRecord 模型

**Files:**
- Create: `agentGui/Models/SubagentTaskRecord.swift`

### Step 1: 新建模型文件

```swift
// agentGui/Models/SubagentTaskRecord.swift
import Foundation
import SwiftData

// MARK: - SubagentTaskStatus

/// 子代理任务的生命周期状态。
/// 存储为 `SubagentTaskRecord.statusRaw: String`，计算属性 `status` 提供强类型访问。
enum SubagentTaskStatus: String, Sendable, Codable, Equatable, CaseIterable {
    /// 已创建，等待调度执行
    case pending
    /// 正在执行
    case running
    /// 执行成功并返回结果
    case completed
    /// 执行遇到错误，终止
    case failed
    /// 被外部主动取消
    case cancelled
}

// MARK: - SubagentTaskRecord

/// 子代理任务持久化记录。
///
/// 每次 `run_subagent` 调用都会创建一条记录，后台执行时用于追踪状态、进度和最终结果。
/// 与 Claude Code `LocalAgentTaskState` 对应（`src/tasks/LocalAgentTask/LocalAgentTask.tsx`）。
///
/// **注意：** 此阶段不建立 SwiftData `@Relationship` 与 `ToolCall` / `Session`，
/// 使用 ID 引用（`sessionID`、`parentToolCallID`），关系由 S-C2 按需补充。
@Model
final class SubagentTaskRecord {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    // MARK: - 标识符

    /// 记录唯一 ID，也用作后台子代理的 agentID。
    var id: UUID

    /// 所属会话 ID（不建立 @Relationship，保持迁移兼容性）
    var sessionID: UUID

    /// 触发此子代理的父级 ToolCall ID
    var parentToolCallID: UUID

    // MARK: - 代理描述

    /// 代理类型名称，例如 "verifier" / "explore" / "plan"
    var agentName: String

    /// 5-10 字任务描述（用于 UI 展示）
    var description: String

    /// 原始 task 入参（完整提示词文本）
    var task: String

    // MARK: - 状态机

    /// 状态 rawValue 持久化字段（不直接暴露，使用计算属性 `status`）
    var statusRaw: String

    // MARK: - 模型与时间

    /// 执行此任务使用的模型 ID（nil = 继承父代理）
    var modelID: String?

    /// 任务开始时间
    var startedAt: Date

    /// 任务结束时间（pending/running 时为 nil）
    var completedAt: Date?

    // MARK: - 执行结果

    /// 最终输出文本（status == .completed 时有值）
    var result: String?

    /// 错误信息（status == .failed 时有值）
    var errorMessage: String?

    // MARK: - 进度追踪

    /// 累计工具调用次数（由 S-C3 更新）
    var toolUseCount: Int

    /// 累计 token 消耗（latestInputTokens + cumulativeOutputTokens，由 S-C3 更新）
    var tokenCount: Int

    /// 最近一个工具调用的活动描述，如 "Reading ClaudeService.swift"（由 S-C3 更新）
    var lastActivity: String?

    /// 30 秒滚动摘要短语（由 S-C4 SubagentProgressSummarizer 更新）
    var progressSummary: String?

    // MARK: - 恢复支持

    /// JSONL transcript 文件路径（由 S-G1 SubagentTranscriptStore 写入）
    var transcriptPath: String?

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        parentToolCallID: UUID,
        agentName: String,
        description: String,
        task: String,
        status: SubagentTaskStatus = .pending,
        modelID: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        result: String? = nil,
        errorMessage: String? = nil,
        toolUseCount: Int = 0,
        tokenCount: Int = 0,
        lastActivity: String? = nil,
        progressSummary: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentToolCallID = parentToolCallID
        self.agentName = agentName
        self.description = description
        self.task = task
        self.statusRaw = status.rawValue
        self.modelID = modelID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
        self.errorMessage = errorMessage
        self.toolUseCount = toolUseCount
        self.tokenCount = tokenCount
        self.lastActivity = lastActivity
        self.progressSummary = progressSummary
        self.transcriptPath = transcriptPath
    }
}

// MARK: - Computed Properties

extension SubagentTaskRecord {

    /// 强类型状态访问。未知 rawValue 时 fallback 到 `.pending`。
    var status: SubagentTaskStatus {
        get { SubagentTaskStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// 是否处于终止状态（completed / failed / cancelled）
    var isTerminal: Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        case .pending, .running: return false
        }
    }

    /// 任务已耗费时间（秒）。运行中取当前时间，已结束取 completedAt。
    var elapsedSeconds: TimeInterval {
        let end = completedAt ?? Date()
        return end.timeIntervalSince(startedAt)
    }
}
```

### Step 2: 提交模型文件

```bash
git add agentGui/Models/SubagentTaskRecord.swift
git commit -m "feat(s-c1): add SubagentTaskRecord SwiftData model and SubagentTaskStatus enum"
```

---

## Task 3：注册到 PersistenceSchema

**Files:**
- Modify: `agentGui/agentGuiApp.swift`（`PersistenceSchema.sharedModelTypes` 数组）

### Step 1: 在 sharedModelTypes 末尾追加 SubagentTaskRecord.self

定位 `agentGuiApp.swift` 中 `PersistenceSchema.sharedModelTypes` 数组，在 `ExecutionAttempt.self` 之后追加：

```swift
// 修改前（末尾两行）：
        ExecutionJob.self,
        ExecutionAttempt.self,
    ]

// 修改后：
        ExecutionJob.self,
        ExecutionAttempt.self,
        SubagentTaskRecord.self,
    ]
```

### Step 2: 提交注册修改

```bash
git add agentGui/agentGuiApp.swift
git commit -m "feat(s-c1): register SubagentTaskRecord in PersistenceSchema"
```

---

## Task 4：运行测试，验证全部通过

### Step 1: 运行 SubagentTaskRecord 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-c1-derived \
  -only-testing:agentGuiTests/SubagentTaskRecordTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | head -20
```

期望输出：所有测试显示 `passed`。

### Step 2: 若测试失败，排查顺序

1. 编译错误 → 检查 `SubagentTaskRecord.swift` 中 init 参数与测试调用是否匹配。
2. `test_persistAndFetch_roundTripsAllFields` 失败 → 检查 `makeInMemoryContainer()` 的 `Schema` 是否仅包含 `SubagentTaskRecord.self`（独立 schema，不依赖完整 `PersistenceSchema`）。
3. `test_status_unknownRaw_fallsBackToPending` 失败 → 检查计算属性 `??` fallback 逻辑。

### Step 3: 运行全量 smoke 测试，确认无回归

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-c1-smoke \
  -only-testing:agentGuiTests/SubagentTaskRecordTests \
  -only-testing:agentGuiTests/AgentTeamSessionStateTests \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

期望：`** TEST SUCCEEDED **`

### Step 4: 最终提交

```bash
git add -A
git commit -m "feat(s-c1): complete SubagentTaskRecord with tests and schema registration

- SubagentTaskStatus enum (pending/running/completed/failed/cancelled)
- SubagentTaskRecord @Model with all fields from design doc
- Computed status property with unknown-rawValue fallback
- Computed isTerminal and elapsedSeconds helpers
- Registered in PersistenceSchema.sharedModelTypes
- 7 unit tests covering init defaults, status roundtrip, persistence"
```

---

## 验收检查清单

- [ ] `SubagentTaskRecord` 可通过 SwiftData `ModelContext` 正确持久化和读取
- [ ] `SubagentTaskStatus` 所有 5 种状态均可通过 `statusRaw` 往返
- [ ] 未知 `statusRaw` fallback 到 `.pending`，不 crash
- [ ] `isTerminal` 对 completed/failed/cancelled 返回 `true`，对 pending/running 返回 `false`
- [ ] `elapsedSeconds` 在运行中状态可调用（不 crash）
- [ ] 注册到 `PersistenceSchema.sharedModelTypes`，不影响现有完整 schema 测试
- [ ] 全部 7 条单元测试通过

---

## 后续 Feature 接口预留

S-C2（后台执行器）将使用以下字段的写入：
- `status`（状态流转：pending → running → completed/failed/cancelled）
- `completedAt`（终止时写入）
- `result` / `errorMessage`

S-C3（进度追踪）将使用以下字段的增量更新：
- `toolUseCount`、`tokenCount`、`lastActivity`

S-C4（摘要服务）将写入：
- `progressSummary`

S-G1（transcript store）将写入：
- `transcriptPath`
