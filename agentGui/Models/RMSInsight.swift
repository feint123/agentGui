import Foundation

enum RMSInsightKind: String, Codable, Equatable, Sendable {
    case constraint
    case counterexample
    case tactic
}

struct RMSInsight: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: RMSInsightKind
    var summary: String
    var appliesWhen: String
    var changesDecision: String
    var replacementAction: String?
    var evidenceRefs: [String]
    var scope: MemoryScope?
    var confidence: Double
    var updatedAt: Date?

    init(
        id: String,
        kind: RMSInsightKind,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        replacementAction: String? = nil,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.appliesWhen = appliesWhen
        self.changesDecision = changesDecision
        self.replacementAction = replacementAction
        self.evidenceRefs = evidenceRefs
        self.scope = scope
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    static func constraint(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .constraint,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }

    static func counterexample(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        replacementAction: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .counterexample,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            replacementAction: replacementAction,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }

    static func tactic(
        id: String,
        summary: String,
        appliesWhen: String,
        changesDecision: String,
        evidenceRefs: [String] = [],
        scope: MemoryScope? = nil,
        confidence: Double = 1
    ) -> RMSInsight {
        RMSInsight(
            id: id,
            kind: .tactic,
            summary: summary,
            appliesWhen: appliesWhen,
            changesDecision: changesDecision,
            evidenceRefs: evidenceRefs,
            scope: scope,
            confidence: confidence
        )
    }
}