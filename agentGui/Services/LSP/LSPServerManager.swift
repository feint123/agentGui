import Foundation

@MainActor
final class LSPServerManager {
    enum ManagerError: Error {
        case unknownServerID(String)
        case inactiveSession(workspaceRoot: String, serverID: String)
    }

    let diagnosticsStore: LSPDiagnosticsStore

    private let registry: LSPServerRegistry
    private let makeClient: () -> LSPClient
    private let makeSupervisor: () -> LSPProcessSupervisor
    private var sessions: [SessionKey: SessionRecord] = [:]

    init(
        registry: LSPServerRegistry,
        diagnosticsStore: LSPDiagnosticsStore,
        makeClient: @escaping () -> LSPClient,
        makeSupervisor: @escaping () -> LSPProcessSupervisor
    ) {
        self.registry = registry
        self.diagnosticsStore = diagnosticsStore
        self.makeClient = makeClient
        self.makeSupervisor = makeSupervisor
    }

    var activeSessionCount: Int {
        sessions.count
    }

    func startSession(workspaceRoot: String, serverID: String) async throws -> UUID {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        if let existing = sessions[key] {
            return existing.id
        }

        guard let definition = registry.definition(for: serverID) else {
            throw ManagerError.unknownServerID(serverID)
        }

        let supervisor = makeSupervisor()
        let client = makeClient()
        let process = try await supervisor.start(command: definition.launchCommand, arguments: definition.launchArguments)
        client.attach(process: process)
        supervisor.record(.info, message: "Initializing LSP session for server '\(serverID)' in '\(workspaceRoot)'")

        let capabilities: LSPServerCapabilityHints
        do {
            capabilities = try await client.initializeSession(server: definition, workspaceRoot: workspaceRoot)
            supervisor.record(.info, message: "LSP initialize handshake completed for '\(serverID)'")
        } catch {
            supervisor.record(.error, message: "LSP initialize handshake failed for '\(serverID)': \(error.localizedDescription)")
            await supervisor.stop()
            throw error
        }

        let session = SessionRecord(
            id: UUID(),
            definition: definition,
            supervisor: supervisor,
            client: client,
            capabilities: capabilities
        )
        sessions[key] = session
        return session.id
    }

    func restartServer(workspaceRoot: String, serverID: String) async throws -> UUID {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        if let existing = sessions[key] {
            await existing.supervisor.stop()
            sessions.removeValue(forKey: key)
        }
        return try await startSession(workspaceRoot: workspaceRoot, serverID: serverID)
    }

    func capabilities(for workspaceRoot: String, serverID: String) -> LSPServerCapabilityHints? {
        sessions[SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)]?.capabilities
    }

    func state(for workspaceRoot: String, serverID: String) -> LSPProcessState? {
        sessions[SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)]?.supervisor.state
    }

    func recentLogs(for workspaceRoot: String, serverID: String) -> [LSPRuntimeLogEntry] {
        sessions[SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)]?.supervisor.recentLogs ?? []
    }

    func publishDiagnostics(workspaceRoot: String, serverID: String, uri: String, diagnostics: [LSPDiagnostic]) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }
        session.client.publishDiagnostics(workspaceRoot: workspaceRoot, uri: uri, diagnostics: diagnostics)
    }

    func definition(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> LSPSymbolLocation? {
        let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
        return try await session.client.definition(uri: uri, line: line, character: character)
    }

    func references(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> [LSPSymbolLocation] {
        let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
        return try await session.client.references(uri: uri, line: line, character: character)
    }

    func hover(workspaceRoot: String, serverID: String, uri: String, line: Int, character: Int) async throws -> String? {
        let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
        return try await session.client.hover(uri: uri, line: line, character: character)
    }

    private func sessionRecord(for workspaceRoot: String, serverID: String) throws -> SessionRecord {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else {
            throw ManagerError.inactiveSession(workspaceRoot: workspaceRoot, serverID: serverID)
        }
        return session
    }

    private struct SessionKey: Hashable {
        let workspaceRoot: String
        let serverID: String
    }

    private struct SessionRecord {
        let id: UUID
        let definition: LSPServerDefinition
        let supervisor: LSPProcessSupervisor
        let client: LSPClient
        let capabilities: LSPServerCapabilityHints
    }
}