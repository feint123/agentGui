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
    var budget: AgentTeamBudget
    var initialContextSummary: String
    var providerPlan: AgentTeamProviderPlan

    init(
        objective: String,
        constraints: [String],
        acceptanceCriteria: [String],
        mode: AgentTeamMode,
        budget: AgentTeamBudget,
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
        self.budget = budget
        self.initialContextSummary = initialContextSummary
        self.providerPlan = providerPlan
    }
}

struct AgentTeamBudget: Codable, Equatable, Sendable {
    var maxActiveProviders: Int
    var tokenBudgetText: String
    var costBudgetText: String

    init(
        maxActiveProviders: Int,
        tokenBudgetText: String,
        costBudgetText: String
    ) {
        self.maxActiveProviders = maxActiveProviders
        self.tokenBudgetText = tokenBudgetText
        self.costBudgetText = costBudgetText
    }
}