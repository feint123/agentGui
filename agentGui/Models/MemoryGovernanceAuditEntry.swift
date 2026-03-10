import Foundation

struct MemoryGovernanceAuditEntry: Codable, Equatable, Sendable, Identifiable {
    enum Action: String, Codable, Equatable, Sendable {
        case approved
        case rejected
        case failedToApply
    }

    var id: String
    var candidateID: String
    var action: Action
    var timestamp: Date
    var finalRecordID: String?
    var rejectionReason: String?
    var detail: String?

    init(
        id: String = UUID().uuidString,
        candidateID: String,
        action: Action,
        timestamp: Date = Date(),
        finalRecordID: String? = nil,
        rejectionReason: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.candidateID = candidateID
        self.action = action
        self.timestamp = timestamp
        self.finalRecordID = finalRecordID
        self.rejectionReason = rejectionReason
        self.detail = detail
    }
}