import Foundation

@MainActor
final class ACPProviderRuntimeSupervisor {
    let providerID: ConversationExecutionProviderID

    private let registry: ACPSessionRuntimeRegistry

    init(
        providerID: ConversationExecutionProviderID,
        registry: ACPSessionRuntimeRegistry = ACPSessionRuntimeRegistry()
    ) {
        self.providerID = providerID
        self.registry = registry
    }

    func activation(
        for localSessionID: String,
        make: @Sendable () -> ACPSessionRuntimeActor
    ) async -> ACPSessionRuntimeActor {
        await registry.activation(
            for: SessionRuntimeKey(providerID: providerID, localSessionID: localSessionID),
            make: make
        )
    }

    func activation(for localSessionID: String) async -> ACPSessionRuntimeActor {
        await activation(for: localSessionID) {
            ACPSessionRuntimeActor(
                key: SessionRuntimeKey(providerID: self.providerID, localSessionID: localSessionID)
            )
        }
    }

    func existingActivation(for localSessionID: String) async -> ACPSessionRuntimeActor? {
        await registry.existingActivation(
            for: SessionRuntimeKey(providerID: providerID, localSessionID: localSessionID)
        )
    }

    func rebuildActivation(for localSessionID: String) async -> ACPSessionRuntimeActor {
        await registry.rebuildActivation(
            for: SessionRuntimeKey(providerID: providerID, localSessionID: localSessionID)
        )
    }

    func removeActivation(for localSessionID: String) async {
        await registry.removeActivation(
            for: SessionRuntimeKey(providerID: providerID, localSessionID: localSessionID)
        )
    }

    func shutdownProviderSessions() async {
        await registry.removeAll(providerID: providerID)
    }

    func activeLocalSessionIDs() async -> [String] {
        await registry.localSessionIDs(providerID: providerID)
    }
}