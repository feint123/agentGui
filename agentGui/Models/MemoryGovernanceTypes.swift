import Foundation

struct MemoryRuntimeOutcome: Equatable, Sendable {
    var request: MemoryRuntimeRequest
    var records: [MemoryRecord]
    var notes: [String]

    init(request: MemoryRuntimeRequest, records: [MemoryRecord] = [], notes: [String] = []) {
        self.request = request
        self.records = records
        self.notes = notes
    }
}

struct MemoryCandidate: Equatable, Sendable {
    var id: String
    var layer: MemoryLayer
    var kind: MemoryKind
    var domainProfile: String
    var scope: MemoryScope
    var title: String
    var summary: String
    var payload: MemoryRecord.Payload
    var confidence: Double
    var verificationStatus: MemoryRecord.VerificationStatus
    var sourceRefs: [MemoryRecord.SourceRef]
    var tags: [String]

    static func fixture(
        id: String = UUID().uuidString,
        layer: MemoryLayer = .task,
        kind: MemoryKind = .working,
        domainProfile: String = "coding-task",
        scope: MemoryScope = .session(id: "session-fixture"),
        title: String = "Candidate",
        summary: String = "Candidate summary",
        payload: MemoryRecord.Payload = .text("Candidate summary"),
        confidence: Double = 1.0,
        verificationStatus: MemoryRecord.VerificationStatus = .verified,
        sourceRefs: [MemoryRecord.SourceRef] = [],
        tags: [String] = []
    ) -> MemoryCandidate {
        MemoryCandidate(
            id: id,
            layer: layer,
            kind: kind,
            domainProfile: domainProfile,
            scope: scope,
            title: title,
            summary: summary,
            payload: payload,
            confidence: confidence,
            verificationStatus: verificationStatus,
            sourceRefs: sourceRefs,
            tags: tags
        )
    }
}

struct MemoryConflict: Equatable, Sendable, Identifiable {
    var id: String
    var existingRecordID: String
    var candidateID: String
    var reason: String

    init(id: String = UUID().uuidString, existingRecordID: String, candidateID: String, reason: String) {
        self.id = id
        self.existingRecordID = existingRecordID
        self.candidateID = candidateID
        self.reason = reason
    }
}

enum MemoryGovernanceDecision: String, Equatable, Sendable {
    case acceptHotPath
    case acceptBackground
    case needsUserConfirmation
    case reject
    case archiveOnly
}

struct MemoryGovernanceEvaluation: Equatable, Sendable {
    var route: MemoryGovernanceDecision
    var explanation: MemoryAdmissionExplanation?
}

extension MemoryGovernanceDecision {
    var scoreRoute: MemoryAdmissionScore.Route {
        switch self {
        case .acceptHotPath:
            return .hotPath
        case .acceptBackground:
            return .background
        case .needsUserConfirmation:
            return .confirmation
        case .reject:
            return .reject
        case .archiveOnly:
            return .archiveOnly
        }
    }
}

enum MemoryGovernedWriteResult: Equatable, Sendable {
    case hotPath(MemoryWriteResult)
    case backgroundQueued(recordID: String)
    case archived(MemoryWriteResult)
    case confirmationRequired(MemoryConfirmationCandidate)
    case rejected(reason: String)
}