//
//  ExecutionPlan.swift
//  agentGui
//
//  Structured plan produced by the agent before tackling complex tasks.
//  Also holds the verification record written before a task is declared complete.
//

import Foundation

// MARK: - PlanStepStatus

enum PlanStepStatus: String, Codable, CaseIterable {
    case pending  = "pending"
    case done     = "done"
    case skipped  = "skipped"
    case failed   = "failed"

    var displayName: String {
        switch self {
        case .pending:  return "待执行"
        case .done:     return "已完成"
        case .skipped:  return "已跳过"
        case .failed:   return "失败"
        }
    }

    var icon: String {
        switch self {
        case .pending:  return "circle"
        case .done:     return "checkmark.circle.fill"
        case .skipped:  return "minus.circle"
        case .failed:   return "xmark.circle.fill"
        }
    }
}

// MARK: - PlanStep

struct PlanStep: Codable, Identifiable {
    var id: String
    var title: String
    var status: PlanStepStatus
    /// Optional result note attached when the step completes.
    var result: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        status: PlanStepStatus = .pending,
        result: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.result = result
    }
}

// MARK: - ExecutionPlan

/// A structured execution plan recorded at the start of a complex task.
/// Stored per-session in `ClaudeService.sessionExecutionPlans`.
struct ExecutionPlan: Codable {
    var goal: String
    var steps: [PlanStep]
    var assumptions: [String]
    var successCriteria: [String]
    var createdAt: Date

    init(
        goal: String,
        steps: [PlanStep],
        assumptions: [String] = [],
        successCriteria: [String] = []
    ) {
        self.goal = goal
        self.steps = steps
        self.assumptions = assumptions
        self.successCriteria = successCriteria
        self.createdAt = Date()
    }
}

// MARK: - CompletionVerification

/// Records what the agent explicitly verified (and didn't verify) before finishing.
/// Written via `verify_completion` just before the task ends.
struct CompletionVerification: Codable {
    var verified: [String]
    var notVerified: [String]
    var conclusion: String?
    var recordedAt: Date

    init(verified: [String], notVerified: [String], conclusion: String? = nil) {
        self.verified = verified
        self.notVerified = notVerified
        self.conclusion = conclusion
        self.recordedAt = Date()
    }
}
