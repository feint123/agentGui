import Foundation

protocol LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints
}

struct GenericLSPServerAdapter: LSPServerAdapter {
    func initialize(server: LSPServerDefinition, workspaceRoot: String) async throws -> LSPServerCapabilityHints {
        server.capabilityHints
    }
}