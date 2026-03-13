import Foundation

enum ToolAccessMode: String, Codable, Sendable {
    case readOnly
    case readWrite
    case unrestricted
}

enum ToolGroupID: String, Codable, Sendable {
    case readOnlyEditor
    case readWriteEditor
    case web
    case shell
    case workflowArtifact
}

enum ToolParameterPolicy: Hashable, Sendable {
    case inherit
}

struct ToolGrant: Sendable, Hashable {
    let toolID: String?
    let toolGroupID: ToolGroupID?
    let accessMode: ToolAccessMode
    let parameterPolicy: ToolParameterPolicy
    let allowedContexts: Set<ToolContext>

    init(
        toolID: String,
        accessMode: ToolAccessMode = .unrestricted,
        parameterPolicy: ToolParameterPolicy = .inherit,
        allowedContexts: Set<ToolContext>
    ) {
        self.toolID = toolID
        self.toolGroupID = nil
        self.accessMode = accessMode
        self.parameterPolicy = parameterPolicy
        self.allowedContexts = allowedContexts
    }

    init(
        toolGroupID: ToolGroupID,
        accessMode: ToolAccessMode = .unrestricted,
        parameterPolicy: ToolParameterPolicy = .inherit,
        allowedContexts: Set<ToolContext>
    ) {
        self.toolID = nil
        self.toolGroupID = toolGroupID
        self.accessMode = accessMode
        self.parameterPolicy = parameterPolicy
        self.allowedContexts = allowedContexts
    }
}