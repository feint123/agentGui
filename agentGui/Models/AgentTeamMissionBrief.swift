import Foundation

struct AgentTeamProviderPlan: Codable, Equatable, Sendable {
    var eligibleProviders: [ExecutionProviderReference]
    var preferredConductor: ExecutionProviderReference
    var preferredReviewer: ExecutionProviderReference?
    var dispatchPolicy: AgentTeamDispatchPolicy

    init(
        eligibleProviders: [ExecutionProviderReference],
        preferredConductor: ExecutionProviderReference,
        preferredReviewer: ExecutionProviderReference?,
        dispatchPolicy: AgentTeamDispatchPolicy
    ) {
        self.eligibleProviders = eligibleProviders
        self.preferredConductor = preferredConductor
        self.preferredReviewer = preferredReviewer
        self.dispatchPolicy = dispatchPolicy
    }
}

enum AgentTeamDispatchPolicy: String, Codable, Equatable, Sendable {
    case manualSelection
    case sourceSessionSeeded
    case autoClaim
}

struct AgentTeamMissionBrief: Codable, Equatable, Sendable {
    var objective: String
    var constraints: [String]
    var acceptanceCriteria: [String]
    var mode: AgentTeamMode
    var dispatchBudget: AgentTeamDispatchBudget
    var initialContextSummary: String
    var providerPlan: AgentTeamProviderPlan

    init(
        objective: String,
        constraints: [String],
        acceptanceCriteria: [String],
        mode: AgentTeamMode,
        dispatchBudget: AgentTeamDispatchBudget = AgentTeamDispatchBudget(),
        initialContextSummary: String,
        providerPlan: AgentTeamProviderPlan = AgentTeamProviderPlan(
            eligibleProviders: [.builtIn],
            preferredConductor: .builtIn,
            preferredReviewer: nil,
            dispatchPolicy: .manualSelection
        )
    ) {
        self.objective = objective
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
        self.mode = mode
        self.dispatchBudget = dispatchBudget
        self.initialContextSummary = initialContextSummary
        self.providerPlan = providerPlan
    }
}

// MARK: - Codable Migration (budget → dispatchBudget)
extension AgentTeamMissionBrief {
    enum CodingKeys: String, CodingKey {
        case objective, constraints, acceptanceCriteria
        case mode, dispatchBudget, initialContextSummary, providerPlan
        case legacyBudget = "budget"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(objective, forKey: .objective)
        try c.encode(constraints, forKey: .constraints)
        try c.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        try c.encode(mode, forKey: .mode)
        try c.encode(dispatchBudget, forKey: .dispatchBudget)
        try c.encode(initialContextSummary, forKey: .initialContextSummary)
        try c.encode(providerPlan, forKey: .providerPlan)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objective = try c.decode(String.self, forKey: .objective)
        constraints = try c.decode([String].self, forKey: .constraints)
        acceptanceCriteria = try c.decode([String].self, forKey: .acceptanceCriteria)
        mode = try c.decode(AgentTeamMode.self, forKey: .mode)
        initialContextSummary = try c.decodeIfPresent(String.self, forKey: .initialContextSummary) ?? ""
        providerPlan = try c.decodeIfPresent(AgentTeamProviderPlan.self, forKey: .providerPlan)
            ?? AgentTeamProviderPlan(eligibleProviders: [.builtIn], preferredConductor: .builtIn, preferredReviewer: nil, dispatchPolicy: .manualSelection)

        if let newBudget = try c.decodeIfPresent(AgentTeamDispatchBudget.self, forKey: .dispatchBudget) {
            dispatchBudget = newBudget
        } else if let legacy = try? c.decodeIfPresent(LegacyBudgetDecodable.self, forKey: .legacyBudget) {
            dispatchBudget = AgentTeamDispatchBudget(maxActiveProviders: legacy.maxActiveProviders)
        } else {
            dispatchBudget = AgentTeamDispatchBudget()
        }
    }

    private struct LegacyBudgetDecodable: Decodable {
        let maxActiveProviders: Int
    }
}

struct AgentTeamDispatchBudget: Codable, Equatable, Sendable {
    var maxActiveProviders: Int

    init(maxActiveProviders: Int = 2) {
        self.maxActiveProviders = maxActiveProviders
    }
}