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

    func binding(for sessionID: String, providerID: ConversationExecutionProviderID) -> Binding? {
        _ = sessionID
        _ = providerID
        return nil
    }

    func upsert(_ binding: Binding) {
        _ = binding
    }

    func removeBinding(for sessionID: String, providerID: ConversationExecutionProviderID) {
        _ = sessionID
        _ = providerID
    }

    func removeBindings(for sessionID: String) {
        _ = sessionID
    }
}