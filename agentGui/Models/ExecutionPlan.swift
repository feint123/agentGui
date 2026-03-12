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
struct CompletionVerification: Codable, Equatable {
    /// Self-reported claims recorded by the main agent via `verify_completion`.
    var verified: [String]
    var notVerified: [String]
    var conclusion: String?

    /// Assessed fields stamped later by the dedicated verifier subagent.
    var passed: Bool?
    var summary: String?
    var missingEvidence: [String]
    var riskAreas: [String]
    var recommendedNextAction: String?
    var verifierAgent: String?
    var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case verified
        case notVerified = "not_verified"
        case conclusion
        case passed
        case summary
        case missingEvidence = "missing_evidence"
        case riskAreas = "risk_areas"
        case recommendedNextAction = "recommended_next_action"
        case verifierAgent = "verifier_agent"
        case recordedAt = "recorded_at"
    }

    init(
        verified: [String],
        notVerified: [String],
        conclusion: String? = nil,
        passed: Bool? = nil,
        summary: String? = nil,
        missingEvidence: [String] = [],
        riskAreas: [String] = [],
        recommendedNextAction: String? = nil,
        verifierAgent: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.verified = verified
        self.notVerified = notVerified
        self.conclusion = conclusion
        self.passed = passed
        self.summary = summary
        self.missingEvidence = missingEvidence
        self.riskAreas = riskAreas
        self.recommendedNextAction = recommendedNextAction
        self.verifierAgent = verifierAgent
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verified = try container.decodeIfPresent([String].self, forKey: .verified) ?? []
        notVerified = try container.decodeIfPresent([String].self, forKey: .notVerified) ?? []
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        passed = try container.decodeIfPresent(Bool.self, forKey: .passed)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        riskAreas = try container.decodeIfPresent([String].self, forKey: .riskAreas) ?? []
        recommendedNextAction = try container.decodeIfPresent(String.self, forKey: .recommendedNextAction)
        verifierAgent = try container.decodeIfPresent(String.self, forKey: .verifierAgent)
        recordedAt = try container.decodeIfPresent(Date.self, forKey: .recordedAt) ?? Date()
    }

    mutating func applyAssessment(_ update: VerificationAssessmentUpdate) {
        passed = update.passed
        summary = update.summary
        missingEvidence = update.missingEvidence
        riskAreas = update.riskAreas
        recommendedNextAction = update.recommendedNextAction
        verifierAgent = update.verifierAgent
    }
}

/// Structured verifier assessment merged into the existing completion record.
struct VerificationAssessmentUpdate: Codable, Equatable {
    var passed: Bool
    var summary: String
    var missingEvidence: [String]
    var riskAreas: [String]
    var recommendedNextAction: String?
    var verifierAgent: String?

    init(
        passed: Bool,
        summary: String,
        missingEvidence: [String] = [],
        riskAreas: [String] = [],
        recommendedNextAction: String? = nil,
        verifierAgent: String? = nil
    ) {
        self.passed = passed
        self.summary = summary
        self.missingEvidence = missingEvidence
        self.riskAreas = riskAreas
        self.recommendedNextAction = recommendedNextAction
        self.verifierAgent = verifierAgent
    }
}
