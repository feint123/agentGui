import Foundation

protocol LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints
}

struct GenericLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        server.capabilityHints
    }
}

struct SourceKitLSPAdapter: LSPServerAdapter {
    enum AdapterError: Error {
        case requiresBuildServerConfiguration
    }

    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        throw AdapterError.requiresBuildServerConfiguration
    }
}