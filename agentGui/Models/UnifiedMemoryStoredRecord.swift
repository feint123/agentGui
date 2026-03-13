import Foundation

struct UnifiedMemoryStoredRecord: Codable, Equatable, Sendable, Identifiable {
    enum StoredPayloadKind: String, Codable, Sendable {
        case text
        case structured
    }

    enum StoredSourceKind: String, Codable, Sendable {
        case tool
        case taskMemory
        case userInput
        case system

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case "tool":
                self = .tool
            case "taskMemory", "storyMemory":
                self = .taskMemory
            case "userInput":
                self = .userInput
            case "system":
                self = .system
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported source kind: \(rawValue)")
            }
        }
    }

    var id: String
    var layer: MemoryLayer
    var kind: MemoryKind
    var domainProfile: String
    var scope: MemoryScope
    var title: String
    var summary: String
    var payloadKind: StoredPayloadKind
    var payloadText: String?
    var payloadStructured: [String: String]?
    var sourceKind: StoredSourceKind
    var sourceName: String?
    var sourceRefs: [MemoryRecord.SourceRef]
    var confidence: Double
    var verificationStatus: MemoryRecord.VerificationStatus
    var retentionPolicy: MemoryRecord.RetentionPolicy
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var supersededBy: String?
    var tags: [String]

    init(record: MemoryRecord) {
        id = record.id
        layer = record.layer
        kind = record.kind
        domainProfile = record.domainProfile
        scope = record.scope
        title = record.title
        summary = record.summary

        switch record.payload {
        case let .text(text):
            payloadKind = .text
            payloadText = text
            payloadStructured = nil
        case let .structured(fields):
            payloadKind = .structured
            payloadText = nil
            payloadStructured = fields
        }

        switch record.source {
        case let .tool(name):
            sourceKind = .tool
            sourceName = name
        case .taskMemory:
            sourceKind = .taskMemory
            sourceName = nil
        case .userInput:
            sourceKind = .userInput
            sourceName = nil
        case let .system(name):
            sourceKind = .system
            sourceName = name
        }

        sourceRefs = record.sourceRefs
        confidence = record.confidence
        verificationStatus = record.verificationStatus
        retentionPolicy = record.retentionPolicy
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        lastAccessedAt = record.lastAccessedAt
        supersededBy = record.supersededBy
        tags = record.tags
    }

    func toMemoryRecord() throws -> MemoryRecord {
        let payload: MemoryRecord.Payload
        switch payloadKind {
        case .text:
            payload = .text(payloadText ?? summary)
        case .structured:
            guard let payloadStructured else {
                throw MemoryStoreError.serializationFailed("Missing structured payload for record \(id)")
            }
            payload = .structured(payloadStructured)
        }

        let source: MemoryRecord.Source
        switch sourceKind {
        case .tool:
            source = .tool(name: sourceName ?? "unknown")
        case .taskMemory:
            source = .taskMemory
        case .userInput:
            source = .userInput
        case .system:
            source = .system(name: sourceName ?? "system")
        }

        return MemoryRecord(
            id: id,
            layer: layer,
            kind: kind,
            domainProfile: domainProfile,
            scope: scope,
            title: title,
            summary: summary,
            payload: payload,
            source: source,
            sourceRefs: sourceRefs,
            confidence: confidence,
            verificationStatus: verificationStatus,
            retentionPolicy: retentionPolicy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAccessedAt: lastAccessedAt,
            supersededBy: supersededBy,
            tags: tags
        )
    }
}