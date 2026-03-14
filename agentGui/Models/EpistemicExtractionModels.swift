import Foundation

enum EpistemicObjectKind: String, Codable, Equatable, Sendable {
    case frontier
    case counterexample
    case constraint
    case verificationDebt
    case tacticKernel
    case atomicEvent
}

enum EpistemicEvidenceLevel: String, Codable, Equatable, Sendable {
    case none
    case partial
    case verified
}

struct EpistemicObjectCandidate: Codable, Equatable, Sendable, Identifiable {
    var kind: EpistemicObjectKind
    var id: String
    var summary: String
    var sourceRefs: [String]
    var decisionDelta: String
    var evidenceLevel: EpistemicEvidenceLevel

    enum CodingKeys: String, CodingKey {
        case kind
        case id
        case summary
        case sourceRefs = "source_refs"
        case decisionDelta = "decision_delta"
        case evidenceLevel = "evidence_level"
    }

    init(
        kind: EpistemicObjectKind,
        id: String,
        summary: String,
        sourceRefs: [String] = [],
        decisionDelta: String,
        evidenceLevel: EpistemicEvidenceLevel
    ) {
        self.kind = kind
        self.id = id
        self.summary = summary
        self.sourceRefs = sourceRefs
        self.decisionDelta = decisionDelta
        self.evidenceLevel = evidenceLevel
    }
}

struct RejectedEpistemicObject: Codable, Equatable, Sendable {
    var summary: String
    var reason: String
}

struct EpistemicExtractionOutput: Codable, Equatable, Sendable {
    var objects: [EpistemicObjectCandidate]
    var rejected: [RejectedEpistemicObject]
    var missingEvidence: [String]
    var decisionImpactNote: String

    init(
        objects: [EpistemicObjectCandidate] = [],
        rejected: [RejectedEpistemicObject] = [],
        missingEvidence: [String] = [],
        decisionImpactNote: String = ""
    ) {
        self.objects = objects
        self.rejected = rejected
        self.missingEvidence = missingEvidence
        self.decisionImpactNote = decisionImpactNote
    }

    enum CodingKeys: String, CodingKey {
        case objects
        case rejected
        case missingEvidence
        case decisionImpactNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objects = try container.decodeIfPresent([EpistemicObjectCandidate].self, forKey: .objects) ?? []
        rejected = try container.decodeIfPresent([RejectedEpistemicObject].self, forKey: .rejected) ?? []
        missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        decisionImpactNote = try container.decodeIfPresent(String.self, forKey: .decisionImpactNote) ?? ""
    }
}