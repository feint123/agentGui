import Foundation

struct MemoryRecord: Equatable, Sendable, Identifiable {
    enum Payload: Equatable, Sendable {
        case text(String)
        case structured([String: String])
    }

    enum Source: Equatable, Sendable {
        case tool(name: String)
        case taskMemory
        case storyMemory
        case userInput
        case system(name: String)
    }

    struct SourceRef: Equatable, Sendable, Codable {
        var kind: String
        var identifier: String

        init(kind: String, identifier: String) {
            self.kind = kind
            self.identifier = identifier
        }
    }

    enum VerificationStatus: String, Codable, Equatable, Sendable {
        case verified
        case unverified
        case partial
        case failed
    }

    enum RetentionPolicy: String, Codable, Equatable, Sendable {
        case sessionBound
        case projectBound
        case persistent
        case archiveOnly
    }

    var id: String
    var layer: MemoryLayer
    var kind: MemoryKind
    var domainProfile: String
    var scope: MemoryScope
    var title: String
    var summary: String
    var payload: Payload
    var source: Source
    var sourceRefs: [SourceRef]
    var confidence: Double
    var verificationStatus: VerificationStatus
    var retentionPolicy: RetentionPolicy
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var supersededBy: String?
    var tags: [String]
}

extension MemoryRecord {
    static func fixture(
        id: String = UUID().uuidString,
        layer: MemoryLayer = .working,
        kind: MemoryKind = .working,
        domainProfile: String = "coding-task",
        scope: MemoryScope = .session(id: "session-fixture"),
        title: String = "Fixture Memory",
        summary: String = "Fixture summary",
        payload: Payload = .text("Fixture summary"),
        source: Source = .system(name: "tests"),
        sourceRefs: [SourceRef] = [],
        confidence: Double = 1.0,
        verificationStatus: VerificationStatus = .verified,
        retentionPolicy: RetentionPolicy = .sessionBound,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lastAccessedAt: Date? = nil,
        supersededBy: String? = nil,
        tags: [String] = []
    ) -> MemoryRecord {
        MemoryRecord(
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

extension MemoryRecord {
    func replacing(lastAccessedAt: Date? = nil, supersededBy: String? = nil, retentionPolicy: RetentionPolicy? = nil, updatedAt: Date? = nil) -> MemoryRecord {
        MemoryRecord(
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
            retentionPolicy: retentionPolicy ?? self.retentionPolicy,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            lastAccessedAt: lastAccessedAt ?? self.lastAccessedAt,
            supersededBy: supersededBy ?? self.supersededBy,
            tags: tags
        )
    }
}