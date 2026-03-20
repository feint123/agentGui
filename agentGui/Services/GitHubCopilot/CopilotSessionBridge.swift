import Foundation

actor CopilotSessionBridge {
    struct Binding: Codable, Equatable, Sendable {
        let sessionID: String
        let providerID: ConversationExecutionProviderID
        let remoteSessionID: String
        var cliVersion: String?
        var lastHandshakeAt: Date?
        var lastSelectedModel: String?
        var lastSelectedAgentName: String?
    }

    private var bindingsBySessionID: [String: Binding] = [:]

    func binding(for sessionID: String) -> Binding? {
        bindingsBySessionID[sessionID]
    }

    func upsert(_ binding: Binding) {
        bindingsBySessionID[binding.sessionID] = binding
    }

    func removeBinding(for sessionID: String) {
        bindingsBySessionID.removeValue(forKey: sessionID)
    }
}