import Foundation

struct AgentTeamMissionBrief: Codable, Equatable, Sendable {
    var objective: String
    var constraints: [String]
    var acceptanceCriteria: [String]
    var mode: AgentTeamMode
    var budget: AgentTeamBudget
    var initialContextSummary: String

    init(
        objective: String,
        constraints: [String],
        acceptanceCriteria: [String],
        mode: AgentTeamMode,
        budget: AgentTeamBudget,
        initialContextSummary: String
    ) {
        self.objective = objective
        self.constraints = constraints
        self.acceptanceCriteria = acceptanceCriteria
        self.mode = mode
        self.budget = budget
        self.initialContextSummary = initialContextSummary
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