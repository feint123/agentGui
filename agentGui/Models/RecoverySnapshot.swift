import Foundation
import SwiftData

enum RecoverySourceKind: String, Codable, CaseIterable {
    case workflow
    case messageGeneration
    case bashTask

    var displayName: String {
        switch self {
        case .workflow:
            return "工作流"
        case .messageGeneration:
            return "消息生成"
        case .bashTask:
            return "Bash 任务"
        }
    }
}

enum RecoveryHandlingState: String, Codable, CaseIterable {
    case pending
    case viewed
    case interrupted
    case cleared

    var isVisible: Bool {
        switch self {
        case .pending, .viewed:
            return true
        case .interrupted, .cleared:
            return false
        }
    }
}

struct RecoverySummary {
    var items: [RecoverySnapshot]
}

@Model
final class RecoverySnapshot {
    var id: UUID
    var sessionId: String
    var sourceKindRaw: String
    var sourceIdentifier: String
    var summaryText: String
    var metadataJSON: String
    var handlingStateRaw: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionId: String,
        sourceKind: RecoverySourceKind,
        sourceIdentifier: String,
        summaryText: String,
        metadata: [String: String] = [:],
        handlingState: RecoveryHandlingState = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceIdentifier = sourceIdentifier
        self.summaryText = summaryText
        self.handlingStateRaw = handlingState.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = (try? String(data: JSONEncoder().encode(metadata), encoding: .utf8)) ?? "{}"
    }
}

extension RecoverySnapshot {
    var sourceKind: RecoverySourceKind {
        RecoverySourceKind(rawValue: sourceKindRaw) ?? .messageGeneration
    }

    var handlingState: RecoveryHandlingState {
        get { RecoveryHandlingState(rawValue: handlingStateRaw) ?? .pending }
        set {
            handlingStateRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var metadata: [String: String] {
        guard let data = metadataJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}