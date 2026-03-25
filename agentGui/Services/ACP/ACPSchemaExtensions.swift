import Foundation

struct ACPMcpCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var http: Bool?
    var sse: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case http
        case sse
    }
}

struct ACPSessionListCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var pageSize: Int?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case pageSize
    }
}

struct ACPSessionCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var list: ACPSessionListCapabilities?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case list
    }
}

struct ACPSessionMode: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var description: String?
    var id: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case description
        case id
        case name
    }
}

enum ACPSessionConfigOptionCategory: Codable, Equatable, Sendable {
    case mode
    case model
    case thoughtLevel
    case other(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ACPSessionConfigOptionCategory(rawValue: rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue {
        case "mode": self = .mode
        case "model": self = .model
        case "thought_level": self = .thoughtLevel
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .mode: return "mode"
        case .model: return "model"
        case .thoughtLevel: return "thought_level"
        case .other(let rawValue): return rawValue
        }
    }
}

struct ACPSessionConfigSelectOption: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var description: String?
    var name: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case description
        case name
        case value
    }
}

struct ACPSessionConfigSelectGroup: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var group: String
    var name: String
    var options: [ACPSessionConfigSelectOption]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case group
        case name
        case options
    }
}

enum ACPSessionConfigSelectOptions: Codable, Equatable, Sendable {
    case ungrouped([ACPSessionConfigSelectOption])
    case grouped([ACPSessionConfigSelectGroup])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let grouped = try? container.decode([ACPSessionConfigSelectGroup].self) {
            self = .grouped(grouped)
            return
        }

        self = .ungrouped(try container.decode([ACPSessionConfigSelectOption].self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ungrouped(let options):
            try container.encode(options)
        case .grouped(let groups):
            try container.encode(groups)
        }
    }
}

struct ACPSessionConfigOption: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var id: String?
    var category: ACPSessionConfigOptionCategory?
    var currentValue: String
    var options: ACPSessionConfigSelectOptions
    var type: String

    init(
        meta: [String: ACPJSONValue]? = nil,
        id: String? = nil,
        category: ACPSessionConfigOptionCategory? = nil,
        currentValue: String,
        options: ACPSessionConfigSelectOptions,
        type: String
    ) {
        self.meta = meta
        self.id = id
        self.category = category
        self.currentValue = currentValue
        self.options = options
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case id
        case category
        case currentValue
        case options
        case type
    }
}

extension ACPSessionConfigSelectOptions {
    var flattenedOptions: [ACPSessionConfigSelectOption] {
        switch self {
        case .ungrouped(let options):
            return options
        case .grouped(let groups):
            return groups.flatMap(\.options)
        }
    }
}

extension ACPSessionConfigOption {
    var normalizedID: String? {
        id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedOptionValues: Set<String> {
        Set(options.flattenedOptions.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    var isApprovalModeCandidate: Bool {
        let values = normalizedOptionValues
        return values.contains("default") && values.contains("never")
    }
}

extension ACPExternalAgentSessionConfigurationSnapshot {
    func configOption(category: ACPSessionConfigOptionCategory) -> ACPSessionConfigOption? {
        configOptions.first { option in
            option.category == category && option.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    func configOption(idCandidates: Set<String>) -> ACPSessionConfigOption? {
        configOptions.first { option in
            guard let normalizedID = option.normalizedID else { return false }
            return idCandidates.contains(normalizedID)
        }
    }

    var modelConfigOption: ACPSessionConfigOption? {
        configOption(category: .model) ?? configOption(idCandidates: ["model"])
    }

    var approvalConfigOption: ACPSessionConfigOption? {
        configOption(idCandidates: ["approvalmode", "approval_mode", "approval-mode", "approvals"])
            ?? configOptions.first { $0.id != nil && $0.isApprovalModeCandidate }
    }
}

struct ACPSessionModeState: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var availableModes: [ACPSessionMode]
    var currentModeID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case availableModes
        case currentModeID = "currentModeId"
    }
}

struct ACPCurrentModeUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var currentModeID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case currentModeID = "currentModeId"
    }
}

struct ACPConfigOptionUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPSessionConfigOption]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
    }
}

struct ACPSessionInfoUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var title: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case title
        case updatedAt
    }
}

struct ACPImageContentBlock: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var annotations: ACPJSONValue?
    var data: String
    var mimeType: String?
    var type: String = "image"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations
        case data
        case mimeType
        case type
    }
}

struct ACPAudioContentBlock: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var annotations: ACPJSONValue?
    var data: String
    var mimeType: String?
    var type: String = "audio"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations
        case data
        case mimeType
        case type
    }
}

struct ACPToolCallLocation: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var path: String?
    var line: Int?
    var column: Int?
    var uri: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case path
        case line
        case column
        case uri
    }
}

enum ACPToolKind: Codable, Equatable, Sendable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode
    case other(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ACPToolKind(rawValue: rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue {
        case "read": self = .read
        case "edit": self = .edit
        case "delete": self = .delete
        case "move": self = .move
        case "search": self = .search
        case "execute": self = .execute
        case "think": self = .think
        case "fetch": self = .fetch
        case "switch_mode": self = .switchMode
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .read: return "read"
        case .edit: return "edit"
        case .delete: return "delete"
        case .move: return "move"
        case .search: return "search"
        case .execute: return "execute"
        case .think: return "think"
        case .fetch: return "fetch"
        case .switchMode: return "switch_mode"
        case .other(let rawValue): return rawValue
        }
    }
}

enum ACPToolCallStatus: Codable, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case other(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ACPToolCallStatus(rawValue: rawValue)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    init(rawValue: String) {
        switch rawValue {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .failed: return "failed"
        case .other(let rawValue): return rawValue
        }
    }
}