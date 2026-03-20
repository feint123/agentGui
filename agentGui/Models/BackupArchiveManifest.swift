import Foundation

enum BackupArchiveScope: Codable, Equatable {
    case allData
    case singleSession(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case sessionId
    }

    private enum Kind: String, Codable {
        case allData
        case singleSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .allData:
            self = .allData
        case .singleSession:
            self = .singleSession(try container.decode(String.self, forKey: .sessionId))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allData:
            try container.encode(Kind.allData, forKey: .kind)
        case .singleSession(let sessionId):
            try container.encode(Kind.singleSession, forKey: .kind)
            try container.encode(sessionId, forKey: .sessionId)
        }
    }
}

struct BackupArchiveManifest: Codable, Equatable {
    var schemaVersion: Int
    var createdAt: Date
    var scope: BackupArchiveScope
    var sessionIDs: [String]
}

struct BackupArchivePayload: Codable, Equatable {
    var appSettings: AppSettingsArchive?
    var sessions: [SessionArchive]
    var messages: [MessageArchive]
    var toolCalls: [ToolCallArchive]
    var taskStates: [SessionTaskStateArchive]
}

struct AppSettingsArchive: Codable, Equatable {
    var apiKey: String
    var baseURL: String
    var selectedModel: String
    var themeMode: ThemeMode
    var workingDirectory: String
}

struct SessionArchive: Codable, Equatable {
    var sessionId: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isActive: Bool
    var workingDirectory: String
    var planJson: String
}

struct MessageArchive: Codable, Equatable {
    var id: UUID
    var sessionId: String
    var direction: MessageDirection
    var contentType: ContentType
    var textContent: String?
    var status: MessageStatus
    var sequence: Int
    var timestamp: Date
    var errorMessage: String?
}

struct ToolCallArchive: Codable, Equatable {
    var id: UUID
    var toolCallId: String
    var kind: ToolKind
    var title: String?
    var status: ToolStatus
    var messageId: UUID?
    var startTime: Date?
    var endTime: Date?
}

struct SessionTaskStateArchive: Codable, Equatable {
    var sessionId: String
    var planJson: String
    var todoJson: String
    var verificationJson: String
    var updatedAt: Date

    init(
        sessionId: String,
        planJson: String,
        todoJson: String = "[]",
        verificationJson: String = "",
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.planJson = planJson
        self.todoJson = todoJson
        self.verificationJson = verificationJson
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case planJson
        case todoJson
        case verificationJson
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.planJson = try container.decodeIfPresent(String.self, forKey: .planJson) ?? ""
        self.todoJson = try container.decodeIfPresent(String.self, forKey: .todoJson) ?? "[]"
        self.verificationJson = try container.decodeIfPresent(String.self, forKey: .verificationJson) ?? ""
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}