import Foundation

actor ExternalACPTerminalRuntimeStore {
    private var bashTaskRegistries: [String: BashTaskRegistry] = [:]
    private var terminalTaskRuntimes: [String: TerminalTaskRuntime] = [:]

    private func runtimeKey(
        for sessionId: String,
        providerID: ConversationExecutionProviderID
    ) -> String {
        "external-acp:\(providerID.rawValue):\(sessionId)"
    }

    private func runtimeKey(
        for sessionId: String,
        providerReference: ExecutionProviderReference
    ) -> String {
        "external-acp:\(providerReference.persistedValue):\(sessionId)"
    }

    func runtime(
        for sessionId: String,
        providerID: ConversationExecutionProviderID,
        workingDirectory: String?
    ) -> TerminalTaskRuntime {
        let runtimeKey = runtimeKey(for: sessionId, providerID: providerID)
        if let existing = terminalTaskRuntimes[runtimeKey] {
            print("[bash-runtime] reuse runtime session=\(runtimeKey) workingDirectory=\(workingDirectory ?? "nil")")
            return existing
        }

        let registry: BashTaskRegistry
        if let existingRegistry = bashTaskRegistries[runtimeKey] {
            registry = existingRegistry
        } else {
            let createdRegistry = BashTaskRegistry()
            bashTaskRegistries[runtimeKey] = createdRegistry
            registry = createdRegistry
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-terminal", isDirectory: true)
            .appendingPathComponent(runtimeKey, isDirectory: true)
        print("[bash-runtime] create runtime session=\(runtimeKey) workingDirectory=\(workingDirectory ?? "nil") baseDirectory=\(baseDirectory.path)")
        let runtime = TerminalTaskRuntime(
            registry: registry,
            transcriptStore: TerminalTranscriptStore(baseDirectory: baseDirectory),
            sessionId: runtimeKey
        )
        terminalTaskRuntimes[runtimeKey] = runtime
        return runtime
    }

    func runtime(
        for sessionId: String,
        providerReference: ExecutionProviderReference,
        workingDirectory: String?
    ) -> TerminalTaskRuntime {
        let runtimeKey = runtimeKey(for: sessionId, providerReference: providerReference)
        if let existing = terminalTaskRuntimes[runtimeKey] {
            print("[bash-runtime] reuse runtime session=\(runtimeKey) workingDirectory=\(workingDirectory ?? "nil")")
            return existing
        }

        let registry: BashTaskRegistry
        if let existingRegistry = bashTaskRegistries[runtimeKey] {
            registry = existingRegistry
        } else {
            let createdRegistry = BashTaskRegistry()
            bashTaskRegistries[runtimeKey] = createdRegistry
            registry = createdRegistry
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-terminal", isDirectory: true)
            .appendingPathComponent(runtimeKey, isDirectory: true)
        print("[bash-runtime] create runtime session=\(runtimeKey) workingDirectory=\(workingDirectory ?? "nil") baseDirectory=\(baseDirectory.path)")
        let runtime = TerminalTaskRuntime(
            registry: registry,
            transcriptStore: TerminalTranscriptStore(baseDirectory: baseDirectory),
            sessionId: runtimeKey
        )
        terminalTaskRuntimes[runtimeKey] = runtime
        return runtime
    }

    func reset(
        for sessionId: String,
        providerID: ConversationExecutionProviderID
    ) {
        let runtimeKey = runtimeKey(for: sessionId, providerID: providerID)
        bashTaskRegistries.removeValue(forKey: runtimeKey)
        terminalTaskRuntimes.removeValue(forKey: runtimeKey)
    }

    func reset(
        for sessionId: String,
        providerReference: ExecutionProviderReference
    ) {
        let runtimeKey = runtimeKey(for: sessionId, providerReference: providerReference)
        bashTaskRegistries.removeValue(forKey: runtimeKey)
        terminalTaskRuntimes.removeValue(forKey: runtimeKey)
    }

    func resetAll() {
        bashTaskRegistries.removeAll()
        terminalTaskRuntimes.removeAll()
    }
}

extension ClaudeService {
    func externalACPSessionRuntimeKey(
        for sessionId: String,
        providerID: ConversationExecutionProviderID
    ) -> String {
        "external-acp:\(providerID.rawValue):\(sessionId)"
    }

    func getBashTaskRegistry(for sessionId: String) -> BashTaskRegistry {
        if let existing = bashTaskRegistries[sessionId] { return existing }
        let registry = BashTaskRegistry()
        bashTaskRegistries[sessionId] = registry
        return registry
    }

    func getTerminalTaskRuntime(
        for sessionId: String,
        workingDirectory: String?
    ) -> TerminalTaskRuntime {
        if let existing = terminalTaskRuntimes[sessionId] {
            print("[bash-runtime] reuse runtime session=\(sessionId) workingDirectory=\(workingDirectory ?? "nil")")
            return existing
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-terminal", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        print("[bash-runtime] create runtime session=\(sessionId) workingDirectory=\(workingDirectory ?? "nil") baseDirectory=\(baseDirectory.path)")
        let runtime = TerminalTaskRuntime(
            registry: getBashTaskRegistry(for: sessionId),
            transcriptStore: TerminalTranscriptStore(baseDirectory: baseDirectory),
            sessionId: sessionId
        )
        terminalTaskRuntimes[sessionId] = runtime
        return runtime
    }

    func getExternalACPTerminalTaskRuntime(
        for sessionId: String,
        providerID: ConversationExecutionProviderID,
        workingDirectory: String?
    ) -> TerminalTaskRuntime {
        getTerminalTaskRuntime(for: externalACPSessionRuntimeKey(for: sessionId, providerID: providerID), workingDirectory: workingDirectory)
    }

    func resetExternalACPTerminalTaskRuntime(
        for sessionId: String,
        providerID: ConversationExecutionProviderID
    ) {
        let runtimeKey = externalACPSessionRuntimeKey(for: sessionId, providerID: providerID)
        bashTaskRegistries.removeValue(forKey: runtimeKey)
        terminalTaskRuntimes.removeValue(forKey: runtimeKey)
    }
}