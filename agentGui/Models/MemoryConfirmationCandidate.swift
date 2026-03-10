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
    var status: MemoryConfirmationStatus
    var resolvedAt: Date?
    var finalRecordID: String?
    var rejectionReason: String?

    init(
        id: String = UUID().uuidString,
        candidateID: String,
        domainProfile: String,
        scope: MemoryScope,
        title: String,
        summary: String,
        proposedRecord: UnifiedMemoryStoredRecord,
        reason: String,
        createdAt: Date = Date(),
        status: MemoryConfirmationStatus = .pending,
        resolvedAt: Date? = nil,
        finalRecordID: String? = nil,
        rejectionReason: String? = nil
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
        self.status = status
        self.resolvedAt = resolvedAt
        self.finalRecordID = finalRecordID
        self.rejectionReason = rejectionReason
    }
}

extension MemoryConfirmationCandidate {
    enum CodingKeys: String, CodingKey {
        case id
        case candidateID
        case domainProfile
        case scope
        case title
        case summary
        case proposedRecord
        case reason
        case createdAt
        case status
        case resolvedAt
        case finalRecordID
        case rejectionReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        candidateID = try container.decode(String.self, forKey: .candidateID)
        domainProfile = try container.decode(String.self, forKey: .domainProfile)
        scope = try container.decode(MemoryScope.self, forKey: .scope)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        proposedRecord = try container.decode(UnifiedMemoryStoredRecord.self, forKey: .proposedRecord)
        reason = try container.decode(String.self, forKey: .reason)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decodeIfPresent(MemoryConfirmationStatus.self, forKey: .status) ?? .pending
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        finalRecordID = try container.decodeIfPresent(String.self, forKey: .finalRecordID)
        rejectionReason = try container.decodeIfPresent(String.self, forKey: .rejectionReason)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(candidateID, forKey: .candidateID)
        try container.encode(domainProfile, forKey: .domainProfile)
        try container.encode(scope, forKey: .scope)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(proposedRecord, forKey: .proposedRecord)
        try container.encode(reason, forKey: .reason)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(finalRecordID, forKey: .finalRecordID)
        try container.encodeIfPresent(rejectionReason, forKey: .rejectionReason)
    }
}