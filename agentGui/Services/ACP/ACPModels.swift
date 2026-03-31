import Foundation

nonisolated struct ACPImplementation: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var name: String
    var title: String?
    var version: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case name
        case title
        case version
    }
}

nonisolated struct ACPFileSystemCapability: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var readTextFile: Bool?
    var writeTextFile: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case readTextFile
        case writeTextFile
    }
}

nonisolated struct ACPClientCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var filesystem: ACPFileSystemCapability?
    var terminal: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case filesystem = "fs"
        case terminal
    }
}

nonisolated struct ACPPromptCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var audio: Bool?
    var embeddedContext: Bool?
    var image: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case audio
        case embeddedContext
        case image
    }
}

nonisolated struct ACPAgentCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var loadSession: Bool?
    var promptCapabilities: ACPPromptCapabilities?
    var mcpCapabilities: ACPMcpCapabilities?
    var sessionCapabilities: ACPSessionCapabilities?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case loadSession
        case promptCapabilities
        case mcpCapabilities
        case sessionCapabilities
    }
}

nonisolated struct ACPAuthMethod: Codable, Equatable, Sendable {
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

nonisolated struct ACPInitializeRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var clientCapabilities: ACPClientCapabilities?
    var clientInfo: ACPImplementation?
    var protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case clientCapabilities
        case clientInfo
        case protocolVersion
    }
}

nonisolated struct ACPInitializeResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var agentCapabilities: ACPAgentCapabilities?
    var agentInfo: ACPImplementation?
    var authMethods: [ACPAuthMethod]?
    var protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case agentCapabilities
        case agentInfo
        case authMethods
        case protocolVersion
    }
}

nonisolated struct ACPNewSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]

    nonisolated
    init(meta: [String: ACPJSONValue]? = nil, cwd: String, mcpServers: [ACPJSONValue] = []) {
        self.meta = meta
        self.cwd = cwd
        self.mcpServers = mcpServers
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case cwd
        case mcpServers
    }
}

nonisolated struct ACPUsage: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var cost: ACPJSONValue?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case inputTokens
        case outputTokens
        case cacheCreationInputTokens
        case cacheReadInputTokens
        case cost
    }
}

nonisolated struct ACPNewSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPSessionConfigOption]?
    var modes: ACPSessionModeState?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case modes
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPLoadSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]
    var sessionID: String

    nonisolated
    init(meta: [String: ACPJSONValue]? = nil, cwd: String, mcpServers: [ACPJSONValue] = [], sessionID: String) {
        self.meta = meta
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case cwd
        case mcpServers
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPLoadSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPSessionConfigOption]?
    var modes: ACPSessionModeState?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case modes
    }
}

nonisolated struct ACPListSessionsRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cursor: String?
    var cwd: String?

    nonisolated
    init(meta: [String: ACPJSONValue]? = nil, cursor: String? = nil, cwd: String? = nil) {
        self.meta = meta
        self.cursor = cursor
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case cursor
        case cwd
    }
}

nonisolated struct ACPSessionInfo: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var sessionID: String
    var title: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case cwd
        case sessionID = "sessionId"
        case title
        case updatedAt
    }
}

nonisolated struct ACPListSessionsResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var nextCursor: String?
    var sessions: [ACPSessionInfo]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case nextCursor
        case sessions
    }
}

nonisolated struct ACPSetSessionModeRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var modeID: String
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case modeID = "modeId"
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPSetSessionModeResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

nonisolated struct ACPSetSessionConfigOptionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configID: String
    var sessionID: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configID = "configId"
        case sessionID = "sessionId"
        case value
    }
}

nonisolated struct ACPSetSessionConfigOptionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPSessionConfigOption]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
    }
}

nonisolated struct ACPAuthenticateRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var methodID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case methodID = "methodId"
    }
}

nonisolated struct ACPAuthenticateResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

nonisolated enum ACPStopReason: String, Codable, Equatable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

nonisolated struct ACPTextContentBlock: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var annotations: ACPJSONValue?
    var text: String
    var type: String = "text"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations
        case text
        case type
    }
}

nonisolated struct ACPResourceLinkContentBlock: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var annotations: ACPJSONValue?
    var description: String?
    var mimeType: String?
    var name: String
    var size: Int?
    var title: String?
    var uri: String
    var type: String = "resource_link"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations
        case description
        case mimeType
        case name
        case size
        case title
        case uri
        case type
    }
}

nonisolated struct ACPEmbeddedResourceContentBlock: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var annotations: ACPJSONValue?
    var resource: ACPJSONValue
    var type: String = "resource"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case annotations
        case resource
        case type
    }
}

nonisolated struct ACPUnknownContentBlock: Codable, Equatable, Sendable {
    var type: String
    var payload: [String: ACPJSONValue]
}

nonisolated enum ACPPromptContentBlock: Codable, Equatable, Sendable {
    case text(ACPTextContentBlock)
    case resourceLink(ACPResourceLinkContentBlock)
    case embeddedResource(ACPEmbeddedResourceContentBlock)
    case image(ACPImageContentBlock)
    case audio(ACPAudioContentBlock)
    case other(ACPUnknownContentBlock)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: ACPJSONValue].self)
        guard let type = payload["type"]?.stringValue else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "ACP content block missing type")
        }

        switch type {
        case "text":
            self = .text(try ACPJSONValue.object(payload).decode(ACPTextContentBlock.self))
        case "resource_link":
            self = .resourceLink(try ACPJSONValue.object(payload).decode(ACPResourceLinkContentBlock.self))
        case "resource":
            self = .embeddedResource(try ACPJSONValue.object(payload).decode(ACPEmbeddedResourceContentBlock.self))
        case "image":
            self = .image(try ACPJSONValue.object(payload).decode(ACPImageContentBlock.self))
        case "audio":
            self = .audio(try ACPJSONValue.object(payload).decode(ACPAudioContentBlock.self))
        default:
            self = .other(ACPUnknownContentBlock(type: type, payload: payload))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .resourceLink(let value):
            try container.encode(value)
        case .embeddedResource(let value):
            try container.encode(value)
        case .image(let value):
            try container.encode(value)
        case .audio(let value):
            try container.encode(value)
        case .other(let value):
            try container.encode(value.payload)
        }
    }
}

nonisolated struct ACPPromptRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var prompt: [ACPPromptContentBlock]
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case prompt
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPPromptResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var stopReason: ACPStopReason
    var usage: ACPUsage?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case stopReason
        case usage
    }
}

nonisolated struct ACPContentChunk: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: ACPPromptContentBlock

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
    }
}

nonisolated struct ACPToolCall: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: [ACPToolCallContent]?
    var kind: ACPToolKind?
    var locations: [ACPToolCallLocation]?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
    var status: ACPToolCallStatus?
    var title: String
    var toolCallID: String

    init(
        meta: [String: ACPJSONValue]? = nil,
        content: [ACPToolCallContent]? = nil,
        kind: ACPToolKind? = nil,
        locations: [ACPToolCallLocation]? = nil,
        rawInput: ACPJSONValue? = nil,
        rawOutput: ACPJSONValue? = nil,
        status: ACPToolCallStatus? = nil,
        title: String,
        toolCallID: String
    ) {
        self.meta = meta
        self.content = content
        self.kind = kind
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.status = status
        self.title = title
        self.toolCallID = toolCallID
    }

    init(
        meta: [String: ACPJSONValue]? = nil,
        content: ACPJSONValue? = nil,
        kind: String? = nil,
        locations: ACPJSONValue? = nil,
        rawInput: ACPJSONValue? = nil,
        rawOutput: ACPJSONValue? = nil,
        status: String? = nil,
        title: String,
        toolCallID: String
    ) {
        self.init(
            meta: meta,
            content: content.flatMap { try? $0.decode([ACPToolCallContent].self) },
            kind: kind.map(ACPToolKind.init(rawValue:)),
            locations: locations.flatMap { try? $0.decode([ACPToolCallLocation].self) },
            rawInput: rawInput,
            rawOutput: rawOutput,
            status: status.map(ACPToolCallStatus.init(rawValue:)),
            title: title,
            toolCallID: toolCallID
        )
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
        case kind
        case locations
        case rawInput
        case rawOutput
        case status
        case title
        case toolCallID = "toolCallId"
    }
}

nonisolated struct ACPToolCallUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: [ACPToolCallContent]?
    var kind: ACPToolKind?
    var locations: [ACPToolCallLocation]?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
    var status: ACPToolCallStatus?
    var title: String?
    var toolCallID: String

    init(
        meta: [String: ACPJSONValue]? = nil,
        content: [ACPToolCallContent]? = nil,
        kind: ACPToolKind? = nil,
        locations: [ACPToolCallLocation]? = nil,
        rawInput: ACPJSONValue? = nil,
        rawOutput: ACPJSONValue? = nil,
        status: ACPToolCallStatus? = nil,
        title: String? = nil,
        toolCallID: String
    ) {
        self.meta = meta
        self.content = content
        self.kind = kind
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.status = status
        self.title = title
        self.toolCallID = toolCallID
    }

    init(
        meta: [String: ACPJSONValue]? = nil,
        content: ACPJSONValue? = nil,
        kind: String? = nil,
        locations: ACPJSONValue? = nil,
        rawInput: ACPJSONValue? = nil,
        rawOutput: ACPJSONValue? = nil,
        status: String? = nil,
        title: String? = nil,
        toolCallID: String
    ) {
        self.init(
            meta: meta,
            content: content.flatMap { try? $0.decode([ACPToolCallContent].self) },
            kind: kind.map(ACPToolKind.init(rawValue:)),
            locations: locations.flatMap { try? $0.decode([ACPToolCallLocation].self) },
            rawInput: rawInput,
            rawOutput: rawOutput,
            status: status.map(ACPToolCallStatus.init(rawValue:)),
            title: title,
            toolCallID: toolCallID
        )
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
        case kind
        case locations
        case rawInput
        case rawOutput
        case status
        case title
        case toolCallID = "toolCallId"
    }
}

// MARK: - ToolCallContent types (ACP Schema ToolCallContent discriminated union)

nonisolated struct ACPToolCallDiffContent: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var path: String
    var newText: String
    var oldText: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case path
        case newText
        case oldText
    }
}

nonisolated struct ACPToolCallTerminalRef: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var terminalId: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case terminalId
    }
}

/// A single element of a ToolCall's `content` array.
/// Discriminated by the `type` field: "content" | "diff" | "terminal"
nonisolated enum ACPToolCallContent: Codable, Equatable, Sendable {
    case content(ACPPromptContentBlock)
    case diff(ACPToolCallDiffContent)
    case terminal(ACPToolCallTerminalRef)
    case other(String, ACPJSONValue)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: ACPJSONValue].self)
        let typeString = payload["type"]?.stringValue ?? ""

        switch typeString {
        case "content":
            guard let contentValue = payload["content"] else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "ToolCallContent type='content' missing 'content' field")
            }
            self = .content(try contentValue.decode(ACPPromptContentBlock.self))
        case "diff":
            self = .diff(try ACPJSONValue.object(payload).decode(ACPToolCallDiffContent.self))
        case "terminal":
            self = .terminal(try ACPJSONValue.object(payload).decode(ACPToolCallTerminalRef.self))
        default:
            self = .other(typeString, .object(payload))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .content(let block):
            var obj: [String: ACPJSONValue] = ["type": .string("content")]
            obj["content"] = try ACPJSONValue.fromEncodable(block)
            try container.encode(obj)
        case .diff(let diff):
            var obj = try ACPJSONValue.fromEncodable(diff).objectValue ?? [:]
            obj["type"] = .string("diff")
            try container.encode(obj)
        case .terminal(let ref):
            var obj = try ACPJSONValue.fromEncodable(ref).objectValue ?? [:]
            obj["type"] = .string("terminal")
            try container.encode(obj)
        case .other(_, let payload):
            try container.encode(payload)
        }
    }
}

// MARK: - UsageUpdate payload (claude-agent-acp extension)

nonisolated struct ACPUsageUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var used: Int?
    var size: Int?
    var cost: ACPJSONValue?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case used
        case size
        case cost
    }
}

nonisolated struct ACPAvailableCommandInput: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var hint: String?

    init(meta: [String: ACPJSONValue]? = nil, hint: String? = nil) {
        self.meta = meta
        self.hint = hint
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case hint
    }
}

nonisolated struct ACPAvailableCommand: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var description: String?
    var input: ACPAvailableCommandInput?
    var name: String

    init(
        meta: [String: ACPJSONValue]? = nil,
        description: String? = nil,
        input: ACPAvailableCommandInput? = nil,
        name: String
    ) {
        self.meta = meta
        self.description = description
        self.input = input
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case description
        case input
        case name
    }
}

nonisolated struct ACPAvailableCommandsUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var availableCommands: [ACPAvailableCommand]

    init(meta: [String: ACPJSONValue]? = nil, availableCommands: [ACPAvailableCommand]) {
        self.meta = meta
        self.availableCommands = availableCommands
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case availableCommands
    }
}

nonisolated enum ACPPlanEntryPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

nonisolated enum ACPPlanEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

nonisolated struct ACPPlanEntry: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: String
    var priority: ACPPlanEntryPriority
    var status: ACPPlanEntryStatus

    init(
        meta: [String: ACPJSONValue]? = nil,
        content: String,
        priority: ACPPlanEntryPriority,
        status: ACPPlanEntryStatus
    ) {
        self.meta = meta
        self.content = content
        self.priority = priority
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
        case priority
        case status
    }
}

nonisolated struct ACPPlanUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var entries: [ACPPlanEntry]

    init(meta: [String: ACPJSONValue]? = nil, entries: [ACPPlanEntry]) {
        self.meta = meta
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case entries
    }
}

nonisolated enum ACPSessionUpdate: Codable, Equatable, Sendable {
    case userMessageChunk(ACPContentChunk)
    case agentMessageChunk(ACPContentChunk)
    case agentThoughtChunk(ACPContentChunk)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCallUpdatePayload)
    case availableCommandsUpdate(ACPAvailableCommandsUpdatePayload)
    case plan(ACPPlanUpdatePayload)
    case currentModeUpdate(ACPCurrentModeUpdatePayload)
    case configOptionUpdate(ACPConfigOptionUpdatePayload)
    case sessionInfoUpdate(ACPSessionInfoUpdatePayload)
    case usageUpdate(ACPUsageUpdatePayload)
    case other(kind: String, payload: ACPJSONValue)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: ACPJSONValue].self)
        guard let kind = payload["sessionUpdate"]?.stringValue else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Session update missing sessionUpdate discriminator")
        }

        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(try ACPJSONValue.object(payload).decode(ACPContentChunk.self))
        case "agent_message_chunk":
            self = .agentMessageChunk(try ACPJSONValue.object(payload).decode(ACPContentChunk.self))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try ACPJSONValue.object(payload).decode(ACPContentChunk.self))
        case "tool_call":
            self = .toolCall(try ACPJSONValue.object(payload).decode(ACPToolCall.self))
        case "tool_call_update":
            self = .toolCallUpdate(try ACPJSONValue.object(payload).decode(ACPToolCallUpdatePayload.self))
        case "available_commands_update":
            self = .availableCommandsUpdate(try ACPJSONValue.object(payload).decode(ACPAvailableCommandsUpdatePayload.self))
        case "plan":
            self = .plan(try ACPJSONValue.object(payload).decode(ACPPlanUpdatePayload.self))
        case "current_mode_update":
            self = .currentModeUpdate(try ACPJSONValue.object(payload).decode(ACPCurrentModeUpdatePayload.self))
        case "config_option_update":
            self = .configOptionUpdate(try ACPJSONValue.object(payload).decode(ACPConfigOptionUpdatePayload.self))
        case "session_info_update":
            self = .sessionInfoUpdate(try ACPJSONValue.object(payload).decode(ACPSessionInfoUpdatePayload.self))
        case "usage_update":
            self = .usageUpdate(try ACPJSONValue.object(payload).decode(ACPUsageUpdatePayload.self))
        default:
            self = .other(kind: kind, payload: .object(payload))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .userMessageChunk(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "user_message_chunk", payload: try ACPJSONValue.fromEncodable(value)))
        case .agentMessageChunk(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "agent_message_chunk", payload: try ACPJSONValue.fromEncodable(value)))
        case .agentThoughtChunk(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "agent_thought_chunk", payload: try ACPJSONValue.fromEncodable(value)))
        case .toolCall(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "tool_call", payload: try ACPJSONValue.fromEncodable(value)))
        case .toolCallUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "tool_call_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .availableCommandsUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "available_commands_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .plan(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "plan", payload: try ACPJSONValue.fromEncodable(value)))
        case .currentModeUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "current_mode_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .configOptionUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "config_option_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .sessionInfoUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "session_info_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .usageUpdate(let value):
            try container.encode(SessionUpdateEnvelope(sessionUpdate: "usage_update", payload: try ACPJSONValue.fromEncodable(value)))
        case .other(_, let payload):
            try container.encode(payload)
        }
    }

    private struct SessionUpdateEnvelope: Encodable {
        let sessionUpdate: String
        let payload: ACPJSONValue

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            var object = payload.objectValue ?? [:]
            object["sessionUpdate"] = .string(sessionUpdate)
            try container.encode(object)
        }
    }
}

nonisolated struct ACPSessionNotification: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var update: ACPSessionUpdate

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case update
    }
}

nonisolated struct ACPCancelNotification: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
    }
}

nonisolated enum ACPPermissionOptionKind: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

nonisolated struct ACPPermissionOption: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var kind: ACPPermissionOptionKind
    var name: String
    var optionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case kind
        case name
        case optionID = "optionId"
    }
}

nonisolated struct ACPSelectedPermissionOutcome: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var optionID: String
    var outcome: String = "selected"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case optionID = "optionId"
        case outcome
    }
}

nonisolated struct ACPDeniedPermissionOutcome: Codable, Equatable, Sendable {
    var outcome: String = "cancelled"

    enum CodingKeys: String, CodingKey {
        case outcome
    }
}

nonisolated enum ACPPermissionOutcome: Codable, Equatable, Sendable {
    case selected(ACPSelectedPermissionOutcome)
    case cancelled(ACPDeniedPermissionOutcome)
    case other(kind: String, payload: ACPJSONValue)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let payload = try container.decode([String: ACPJSONValue].self)
        guard let kind = payload["outcome"]?.stringValue else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Permission outcome missing outcome discriminator")
        }

        switch kind {
        case "selected":
            self = .selected(try ACPJSONValue.object(payload).decode(ACPSelectedPermissionOutcome.self))
        case "cancelled":
            self = .cancelled(try ACPJSONValue.object(payload).decode(ACPDeniedPermissionOutcome.self))
        default:
            self = .other(kind: kind, payload: .object(payload))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .selected(let value):
            try container.encode(value)
        case .cancelled(let value):
            try container.encode(value)
        case .other(_, let payload):
            try container.encode(payload)
        }
    }
}

nonisolated struct ACPRequestPermissionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var options: [ACPPermissionOption]
    var sessionID: String
    var toolCall: ACPToolCallUpdatePayload

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case options
        case sessionID = "sessionId"
        case toolCall
    }
}

nonisolated struct ACPRequestPermissionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var outcome: ACPPermissionOutcome

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case outcome
    }
}

nonisolated struct ACPReadTextFileRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var limit: Int?
    var line: Int?
    var path: String
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case limit
        case line
        case path
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPReadTextFileResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
    }
}

nonisolated struct ACPWriteTextFileRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: String
    var path: String
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
        case path
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPWriteTextFileResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

nonisolated struct ACPEnvVariable: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var name: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case name
        case value
    }
}

nonisolated struct ACPCreateTerminalRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var args: [String]?
    var command: String
    var cwd: String?
    var env: [ACPEnvVariable]?
    var outputByteLimit: Int?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case args
        case command
        case cwd
        case env
        case outputByteLimit
        case sessionID = "sessionId"
    }
}

nonisolated struct ACPCreateTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case terminalID = "terminalId"
    }
}

nonisolated struct ACPTerminalOutputRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

nonisolated struct ACPTerminalExitStatus: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var exitCode: Int?
    var signal: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case exitCode
        case signal
    }
}

nonisolated struct ACPTerminalOutputResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var exitStatus: ACPTerminalExitStatus?
    var output: String
    var truncated: Bool

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case exitStatus
        case output
        case truncated
    }
}

nonisolated struct ACPWaitForTerminalExitRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

nonisolated struct ACPWaitForTerminalExitResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var exitCode: Int?
    var signal: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case exitCode
        case signal
    }
}

nonisolated struct ACPKillTerminalRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

nonisolated struct ACPKillTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

nonisolated struct ACPReleaseTerminalRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

nonisolated struct ACPReleaseTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}