import Foundation

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
        getTerminalTaskRuntime(
            for: externalACPSessionRuntimeKey(for: sessionId, providerID: providerID),
            workingDirectory: workingDirectory
        )
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