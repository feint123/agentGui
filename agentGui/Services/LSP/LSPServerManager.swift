import Foundation

@MainActor
final class LSPServerManager {
    enum ManagerError: Error {
        case unknownServerID(String)
        case inactiveSession(workspaceRoot: String, serverID: String)
    }

    let diagnosticsStore: LSPDiagnosticsStore
    var onPresentationStateDidChange: (() -> Void)?

    private var registry: LSPServerRegistry
    private let makeClient: () -> LSPClient
    private let makeSupervisor: () -> LSPProcessSupervisor
    private var sessions: [SessionKey: SessionRecord] = [:]
    private var pendingLaunches: [SessionKey: Task<UUID, any Error>] = [:]

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
        self.diagnosticsStore.onDidPublish = { [weak self] _ in
            self?.notifyPresentationStateDidChange()
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    func updateRegistry(_ registry: LSPServerRegistry) {
        self.registry = registry
    }

    func startSession(workspaceRoot: String, serverID: String) async throws -> UUID {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        if let existing = sessions[key] {
            return existing.id
        }

        if let pending = pendingLaunches[key] {
            return try await pending.value
        }

        guard let definition = registry.definition(for: serverID) else {
            throw ManagerError.unknownServerID(serverID)
        }

        let launchTask = Task<UUID, any Error> { @MainActor in
            let supervisor = makeSupervisor()
            supervisor.onStateDidChange = { [weak self] _ in
                self?.notifyPresentationStateDidChange()
            }
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
            notifyPresentationStateDidChange()
            return session.id
        }

        pendingLaunches[key] = launchTask
        do {
            let sessionID = try await launchTask.value
            pendingLaunches.removeValue(forKey: key)
            return sessionID
        } catch {
            pendingLaunches.removeValue(forKey: key)
            throw error
        }
    }

    func restartServer(workspaceRoot: String, serverID: String) async throws -> UUID {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        pendingLaunches[key]?.cancel()
        pendingLaunches.removeValue(forKey: key)
        if let existing = sessions[key] {
            await existing.supervisor.stop()
            sessions.removeValue(forKey: key)
            notifyPresentationStateDidChange()
        }
        return try await startSession(workspaceRoot: workspaceRoot, serverID: serverID)
    }

    func stopSession(workspaceRoot: String, serverID: String) async {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        pendingLaunches[key]?.cancel()
        pendingLaunches.removeValue(forKey: key)
        guard let existing = sessions[key] else {
            return
        }

        await existing.supervisor.stop()
        sessions.removeValue(forKey: key)
        notifyPresentationStateDidChange()
    }

    @discardableResult
    func recoverSessionIfNeeded(workspaceRoot: String, serverID: String) async throws -> Bool {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let existing = sessions[key] else {
            return false
        }

        switch existing.supervisor.state {
        case .crashed, .failedToLaunch, .stopped:
            _ = try await restartServer(workspaceRoot: workspaceRoot, serverID: serverID)
            return true
        case .idle, .starting, .running:
            return false
        }
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

    func publishDiagnostics(
        workspaceRoot: String,
        serverID: String,
        uri: String,
        diagnostics: [LSPDiagnostic],
        documentVersion: Int? = nil
    ) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }
        session.client.publishDiagnostics(
            workspaceRoot: workspaceRoot,
            uri: uri,
            diagnostics: diagnostics,
            documentVersion: documentVersion
        )
    }

    func syncDocument(
        workspaceRoot: String,
        serverID: String,
        uri: String,
        languageID: String,
        text: String
    ) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }

        if session.client.updateDocument(uri: uri, text: text) == nil {
            _ = session.client.openDocument(uri: uri, languageID: languageID, text: text)
        }
        notifyPresentationStateDidChange()
    }

    func closeDocument(workspaceRoot: String, serverID: String, uri: String) {
        let key = SessionKey(workspaceRoot: workspaceRoot, serverID: serverID)
        guard let session = sessions[key] else { return }
        session.client.closeDocument(uri: uri)
        notifyPresentationStateDidChange()
    }

    private func notifyPresentationStateDidChange() {
        onPresentationStateDidChange?()
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

    func documentSymbols(workspaceRoot: String, serverID: String, uri: String) async throws -> [LSPDocumentSymbol] {
        let session = try sessionRecord(for: workspaceRoot, serverID: serverID)
        return try await session.client.documentSymbols(uri: uri)
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