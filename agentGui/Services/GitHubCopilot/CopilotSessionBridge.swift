import Foundation

actor CopilotSessionBridge {
    struct Binding: Codable, Equatable, Sendable {
        let sessionID: String
        let providerID: ConversationExecutionProviderID
        let remoteSessionID: String
        var cliVersion: String?
        var negotiatedCapabilities: ACPExternalAgentCapabilitySnapshot?
        var lastHandshakeAt: Date?
        var lastSelectedModel: String?
        var lastSelectedAgentName: String?
    }

    private var bindingsBySessionID: [String: [ConversationExecutionProviderID: Binding]] = [:]

    func binding(for sessionID: String, providerID: ConversationExecutionProviderID) -> Binding? {
        bindingsBySessionID[sessionID]?[providerID]
    }

    func upsert(_ binding: Binding) {
        var bindings = bindingsBySessionID[binding.sessionID] ?? [:]
        bindings[binding.providerID] = binding
        bindingsBySessionID[binding.sessionID] = bindings
    }

    func removeBinding(for sessionID: String, providerID: ConversationExecutionProviderID) {
        guard var bindings = bindingsBySessionID[sessionID] else { return }
        bindings.removeValue(forKey: providerID)
        bindingsBySessionID[sessionID] = bindings.isEmpty ? nil : bindings
    }

    func removeBindings(for sessionID: String) {
        bindingsBySessionID.removeValue(forKey: sessionID)
    }
}