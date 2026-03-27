import Foundation

@MainActor
final class ACPProviderRuntimeSupervisor {
    let providerReference: ExecutionProviderReference

    private let registry: ACPSessionRuntimeRegistry

    init(
        providerReference: ExecutionProviderReference,
        registry: ACPSessionRuntimeRegistry = ACPSessionRuntimeRegistry()
    ) {
        self.providerReference = providerReference
        self.registry = registry
    }

    func activation(
        for localSessionID: String,
        make: @Sendable () -> ACPSessionRuntimeActor
    ) async -> ACPSessionRuntimeActor {
        await registry.activation(
            for: SessionRuntimeKey(providerReference: providerReference, localSessionID: localSessionID),
            make: make
        )
    }

    func activation(for localSessionID: String) async -> ACPSessionRuntimeActor {
        await activation(for: localSessionID) {
            ACPSessionRuntimeActor(
                key: SessionRuntimeKey(providerReference: self.providerReference, localSessionID: localSessionID)
            )
        }
    }

    func existingActivation(for localSessionID: String) async -> ACPSessionRuntimeActor? {
        await registry.existingActivation(
            for: SessionRuntimeKey(providerReference: providerReference, localSessionID: localSessionID)
        )
    }

    func rebuildActivation(for localSessionID: String) async -> ACPSessionRuntimeActor {
        await registry.rebuildActivation(
            for: SessionRuntimeKey(providerReference: providerReference, localSessionID: localSessionID)
        )
    }

    func removeActivation(for localSessionID: String) async {
        await registry.removeActivation(
            for: SessionRuntimeKey(providerReference: providerReference, localSessionID: localSessionID)
        )
    }

    func shutdownProviderSessions() async {
        await registry.removeAll(providerReference: providerReference)
    }

    func activeLocalSessionIDs() async -> [String] {
        await registry.localSessionIDs(providerReference: providerReference)
    }
}