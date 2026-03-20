//
//  WorkflowModels.swift
//  agentGui
//
//  Shared enums for agent-role artifact and message contracts.
//

import Foundation

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
