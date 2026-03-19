import Foundation

struct ACPImplementation: Codable, Equatable, Sendable {
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

struct ACPFileSystemCapability: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var readTextFile: Bool?
    var writeTextFile: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case readTextFile
        case writeTextFile
    }
}

struct ACPClientCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var filesystem: ACPFileSystemCapability?
    var terminal: Bool?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case filesystem = "fs"
        case terminal
    }
}

struct ACPPromptCapabilities: Codable, Equatable, Sendable {
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

struct ACPAgentCapabilities: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var loadSession: Bool?
    var promptCapabilities: ACPPromptCapabilities?
    var mcpCapabilities: ACPJSONValue?
    var sessionCapabilities: ACPJSONValue?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case loadSession
        case promptCapabilities
        case mcpCapabilities
        case sessionCapabilities
    }
}

struct ACPAuthMethod: Codable, Equatable, Sendable {
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

struct ACPInitializeRequest: Codable, Equatable, Sendable {
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

struct ACPInitializeResponse: Codable, Equatable, Sendable {
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

struct ACPNewSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]

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

struct ACPUsage: Codable, Equatable, Sendable {
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

struct ACPNewSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPJSONValue]?
    var models: ACPJSONValue?
    var modes: ACPJSONValue?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case models
        case modes
        case sessionID = "sessionId"
    }
}

struct ACPLoadSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]
    var sessionID: String

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

struct ACPLoadSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPJSONValue]?
    var models: ACPJSONValue?
    var modes: ACPJSONValue?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case models
        case modes
    }
}

struct ACPListSessionsRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cursor: String?
    var cwd: String?

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

struct ACPSessionInfo: Codable, Equatable, Sendable {
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

struct ACPListSessionsResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var nextCursor: String?
    var sessions: [ACPSessionInfo]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case nextCursor
        case sessions
    }
}

struct ACPForkSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]?
    var sessionID: String

    init(meta: [String: ACPJSONValue]? = nil, cwd: String, mcpServers: [ACPJSONValue]? = nil, sessionID: String) {
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

struct ACPForkSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPJSONValue]?
    var models: ACPJSONValue?
    var modes: ACPJSONValue?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case models
        case modes
        case sessionID = "sessionId"
    }
}

struct ACPResumeSessionRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var cwd: String
    var mcpServers: [ACPJSONValue]?
    var sessionID: String

    init(meta: [String: ACPJSONValue]? = nil, cwd: String, mcpServers: [ACPJSONValue]? = nil, sessionID: String) {
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

struct ACPResumeSessionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPJSONValue]?
    var models: ACPJSONValue?
    var modes: ACPJSONValue?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
        case models
        case modes
    }
}

struct ACPSetSessionModeRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var modeID: String
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case modeID = "modeId"
        case sessionID = "sessionId"
    }
}

struct ACPSetSessionModeResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

struct ACPSetSessionModelRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var modelID: String
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case modelID = "modelId"
        case sessionID = "sessionId"
    }
}

struct ACPSetSessionModelResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

struct ACPSetSessionConfigOptionRequest: Codable, Equatable, Sendable {
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

struct ACPSetSessionConfigOptionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var configOptions: [ACPJSONValue]

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case configOptions
    }
}

struct ACPAuthenticateRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var methodID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case methodID = "methodId"
    }
}

struct ACPAuthenticateResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

enum ACPStopReason: String, Codable, Equatable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

struct ACPTextContentBlock: Codable, Equatable, Sendable {
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

struct ACPResourceLinkContentBlock: Codable, Equatable, Sendable {
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

struct ACPEmbeddedResourceContentBlock: Codable, Equatable, Sendable {
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

struct ACPUnknownContentBlock: Codable, Equatable, Sendable {
    var type: String
    var payload: [String: ACPJSONValue]
}

enum ACPPromptContentBlock: Codable, Equatable, Sendable {
    case text(ACPTextContentBlock)
    case resourceLink(ACPResourceLinkContentBlock)
    case embeddedResource(ACPEmbeddedResourceContentBlock)
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
        case .other(let value):
            try container.encode(value.payload)
        }
    }
}

struct ACPPromptRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var prompt: [ACPPromptContentBlock]
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case prompt
        case sessionID = "sessionId"
    }
}

struct ACPPromptResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var stopReason: ACPStopReason
    var usage: ACPUsage?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case stopReason
        case usage
    }
}

struct ACPContentChunk: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: ACPPromptContentBlock

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
    }
}

struct ACPToolCall: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: ACPJSONValue?
    var kind: String?
    var locations: ACPJSONValue?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
    var status: String?
    var title: String
    var toolCallID: String

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

struct ACPToolCallUpdatePayload: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: ACPJSONValue?
    var kind: String?
    var locations: ACPJSONValue?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
    var status: String?
    var title: String?
    var toolCallID: String

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

enum ACPSessionUpdate: Codable, Equatable, Sendable {
    case userMessageChunk(ACPContentChunk)
    case agentMessageChunk(ACPContentChunk)
    case agentThoughtChunk(ACPContentChunk)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCallUpdatePayload)
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

struct ACPSessionNotification: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var update: ACPSessionUpdate

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case update
    }
}

struct ACPCancelNotification: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
    }
}

enum ACPPermissionOptionKind: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

struct ACPPermissionOption: Codable, Equatable, Sendable {
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

struct ACPSelectedPermissionOutcome: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var optionID: String
    var outcome: String = "selected"

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case optionID = "optionId"
        case outcome
    }
}

struct ACPDeniedPermissionOutcome: Codable, Equatable, Sendable {
    var outcome: String = "cancelled"

    enum CodingKeys: String, CodingKey {
        case outcome
    }
}

enum ACPPermissionOutcome: Codable, Equatable, Sendable {
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

struct ACPRequestPermissionRequest: Codable, Equatable, Sendable {
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

struct ACPRequestPermissionResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var outcome: ACPPermissionOutcome

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case outcome
    }
}

struct ACPReadTextFileRequest: Codable, Equatable, Sendable {
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

struct ACPReadTextFileResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var content: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case content
    }
}

struct ACPWriteTextFileRequest: Codable, Equatable, Sendable {
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

struct ACPWriteTextFileResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

struct ACPEnvVariable: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var name: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case name
        case value
    }
}

struct ACPCreateTerminalRequest: Codable, Equatable, Sendable {
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

struct ACPCreateTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case terminalID = "terminalId"
    }
}

struct ACPTerminalOutputRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

struct ACPTerminalExitStatus: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var exitCode: Int?
    var signal: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case exitCode
        case signal
    }
}

struct ACPTerminalOutputResponse: Codable, Equatable, Sendable {
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

struct ACPWaitForTerminalExitRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

struct ACPWaitForTerminalExitResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var exitCode: Int?
    var signal: String?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case exitCode
        case signal
    }
}

struct ACPKillTerminalRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

struct ACPKillTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}

struct ACPReleaseTerminalRequest: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?
    var sessionID: String
    var terminalID: String

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionID = "sessionId"
        case terminalID = "terminalId"
    }
}

struct ACPReleaseTerminalResponse: Codable, Equatable, Sendable {
    var meta: [String: ACPJSONValue]?

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
    }
}