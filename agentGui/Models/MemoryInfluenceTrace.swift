import Foundation

struct MemoryInfluenceTrace: Codable, Equatable, Sendable {
    struct ActionRankingChange: Codable, Equatable, Sendable, Identifiable {
        var id: String { "\(memoryID)-\(toAction)" }
        var memoryID: String
        var fromAction: String
        var toAction: String
        var rationale: String
    }

    struct BlockedPathReason: Codable, Equatable, Sendable, Identifiable {
        var id: String { "\(memoryID)-\(blockedAction)" }
        var memoryID: String
        var blockedAction: String
        var rationale: String
    }

    struct FrontierBudgetDecision: Codable, Equatable, Sendable, Identifiable {
        var id: String { frontierID }
        var frontierID: String
        var allocatedBudget: Int
        var rationale: String
    }

    var activatedMemoryIDs: [String] = []
    var rankedActionIDs: [String] = []
    var blockedActionIDs: [String] = []
    var actionRankingChanges: [ActionRankingChange] = []
    var blockedPathReasons: [BlockedPathReason] = []
    var frontierBudgetDecisions: [FrontierBudgetDecision] = []

    init(
        activatedMemoryIDs: [String] = [],
        rankedActionIDs: [String] = [],
        blockedActionIDs: [String] = [],
        actionRankingChanges: [ActionRankingChange] = [],
        blockedPathReasons: [BlockedPathReason] = [],
        frontierBudgetDecisions: [FrontierBudgetDecision] = []
    ) {
        self.activatedMemoryIDs = activatedMemoryIDs
        self.rankedActionIDs = rankedActionIDs
        self.blockedActionIDs = blockedActionIDs
        self.actionRankingChanges = actionRankingChanges
        self.blockedPathReasons = blockedPathReasons
        self.frontierBudgetDecisions = frontierBudgetDecisions
    }
}