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
    var taskDescription: String

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
        taskDescription: String,
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
        self.taskDescription = taskDescription
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
