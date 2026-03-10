import Foundation

struct MemoryConfirmationCandidate: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var candidateID: String
    var domainProfile: String
    var scope: MemoryScope
    var title: String
    var summary: String
    var proposedRecord: UnifiedMemoryStoredRecord
    var reason: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        candidateID: String,
        domainProfile: String,
        scope: MemoryScope,
        title: String,
        summary: String,
        proposedRecord: UnifiedMemoryStoredRecord,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.candidateID = candidateID
        self.domainProfile = domainProfile
        self.scope = scope
        self.title = title
        self.summary = summary
        self.proposedRecord = proposedRecord
        self.reason = reason
        self.createdAt = createdAt
    }
}