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

    // Custom decoder: the model only sends { id, title }; status and result are optional.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(String.self, forKey: .id)
        title  = try c.decode(String.self, forKey: .title)
        status = try c.decodeIfPresent(PlanStepStatus.self, forKey: .status) ?? .pending
        result = try c.decodeIfPresent(String.self, forKey: .result)
    }
}

// MARK: - ExecutionPlan

/// Canonical plan record shared by both regular tasks and workflow agents.
/// Regular tasks write it via the `create_execution_plan` tool.
/// Workflow agents produce compatible JSON (planner role) which the runtime
/// mirrors onto `Session.planJson` so both paths share a single persisted copy.
struct ExecutionPlan: Codable {
    var goal: String
    var steps: [PlanStep]
    var assumptions: [String]
    var successCriteria: [String]
    var createdAt: Date

    // Snake_case keys to stay compatible with both the tool input schema
    // ("success_criteria") and the workflow planner's JSON output format.
    enum CodingKeys: String, CodingKey {
        case goal
        case steps
        case assumptions
        case successCriteria = "success_criteria"
        case createdAt       = "created_at"
    }

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

    // Custom decoder: workflow plan JSON omits `created_at`; other fields are
    // also treated as optional so partial output from the agent still parses.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal            = try c.decode(String.self, forKey: .goal)
        steps           = try c.decodeIfPresent([PlanStep].self, forKey: .steps) ?? []
        assumptions     = try c.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        successCriteria = try c.decodeIfPresent([String].self, forKey: .successCriteria) ?? []
        createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
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
