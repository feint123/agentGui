//
//  WorkflowModels.swift
//  agentGui
//
//  Shared enums and value-type building blocks for the workflow orchestration layer.
//  These types are used by both the in-memory runtime (WorkflowDefinition.swift) and
//  the SwiftData persistence models (WorkflowInstance, WorkflowArtifactRecord, etc.).
//

import Foundation

// MARK: - WorkflowStatus

enum WorkflowStatus: String, Codable, CaseIterable, Sendable {
    case pending    = "pending"
    case running    = "running"
    case paused     = "paused"
    case completed  = "completed"
    case failed     = "failed"
    case cancelled  = "cancelled"

    var displayName: String {
        switch self {
        case .pending:   return "等待中"
        case .running:   return "运行中"
        case .paused:    return "已暂停"
        case .completed: return "已完成"
        case .failed:    return "失败"
        case .cancelled: return "已取消"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - WorkflowArtifactKind

enum WorkflowArtifactKind: String, Codable, CaseIterable, Sendable {
    case plan               = "plan"
    case explorationReport  = "explorationReport"
    case codePatchSummary   = "codePatchSummary"
    case reviewReport       = "reviewReport"
    case testReport         = "testReport"
    case decisionLog        = "decisionLog"
    case finalAnswer        = "finalAnswer"

    var displayName: String {
        switch self {
        case .plan:              return "执行计划"
        case .explorationReport: return "探索报告"
        case .codePatchSummary:  return "代码变更摘要"
        case .reviewReport:      return "审查报告"
        case .testReport:        return "测试报告"
        case .decisionLog:       return "决策日志"
        case .finalAnswer:       return "最终结果"
        }
    }

    var icon: String {
        switch self {
        case .plan:              return "list.bullet.clipboard"
        case .explorationReport: return "magnifyingglass"
        case .codePatchSummary:  return "chevron.left.forwardslash.chevron.right"
        case .reviewReport:      return "checkmark.seal"
        case .testReport:        return "testtube.2"
        case .decisionLog:       return "brain"
        case .finalAnswer:       return "flag.checkered"
        }
    }
}

// MARK: - ArtifactStatus

enum ArtifactStatus: String, Codable, CaseIterable, Sendable {
    case draft      = "draft"
    case approved   = "approved"
    case rejected   = "rejected"
    case superseded = "superseded"

    var displayName: String {
        switch self {
        case .draft:      return "草稿"
        case .approved:   return "已通过"
        case .rejected:   return "已拒绝"
        case .superseded: return "已覆盖"
        }
    }
}

// MARK: - WorkflowMessageKind

enum WorkflowMessageKind: String, Codable, CaseIterable, Sendable {
    case task           = "task"
    case infoRequest    = "infoRequest"
    case infoResponse   = "infoResponse"
    case handoff        = "handoff"
    case reviewFeedback = "reviewFeedback"
    case approval       = "approval"
    case rejection      = "rejection"
    case statusUpdate   = "statusUpdate"
    case completion     = "completion"
    case escalation     = "escalation"

    var displayName: String {
        switch self {
        case .task:           return "任务"
        case .infoRequest:    return "信息请求"
        case .infoResponse:   return "信息响应"
        case .handoff:        return "任务移交"
        case .reviewFeedback: return "审查反馈"
        case .approval:       return "已通过"
        case .rejection:      return "已拒绝"
        case .statusUpdate:   return "状态更新"
        case .completion:     return "任务完成"
        case .escalation:     return "升级处理"
        }
    }

    /// Higher priority kinds are scheduled before lower ones.
    var schedulingPriority: Int {
        switch self {
        case .reviewFeedback, .infoResponse: return 10
        case .task, .handoff, .rejection:    return 7
        case .infoRequest, .approval:        return 5
        case .statusUpdate, .completion:     return 2
        case .escalation:                    return 1
        }
    }
}

// MARK: - ActivationResultKind

enum ActivationResultKind: String, Codable, Sendable {
    case success    = "success"
    case partial    = "partial"
    case failed     = "failed"
    case escalated  = "escalated"
}

// MARK: - WorkflowBudget

struct WorkflowBudget: Codable, Sendable {
    /// Maximum total agent activation rounds across the whole workflow.
    var maxTotalRounds: Int = 100
    /// Maximum activations per role (prevents one agent from monopolising the workflow).
    var maxActivationsPerRole: Int = 10
    /// Maximum turns (inner loop iterations) per single activation.
    var maxTurnsPerActivation: Int = 16
    /// Wall-clock timeout in seconds; 0 = no limit.
    var timeoutSeconds: Double = 0

    static let `default` = WorkflowBudget()
    static let conservative = WorkflowBudget(
        maxTotalRounds: 50,
        maxActivationsPerRole: 5,
        maxTurnsPerActivation: 8,
        timeoutSeconds: 300
    )
}

// MARK: - WorkflowPolicies

struct WorkflowPolicies: Codable, Sendable {
    /// Seconds without a new artifact or status change before marking workflow as stalled.
    var stallTimeoutSeconds: Double = 120
    /// Maximum retries for a role that keeps failing before triggering escalation.
    var maxRetries: Int = 3
    /// How many identical review findings before triggering replan.
    var repeatFindingThreshold: Int = 2
    /// Whether to allow multiple agents active in the same scheduling tick (MVP: false).
    var allowParallelActivations: Bool = false
    /// Escalate to human on stall.
    var escalateOnStall: Bool = true

    static let `default` = WorkflowPolicies()
}
