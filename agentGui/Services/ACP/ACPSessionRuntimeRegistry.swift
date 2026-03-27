import Foundation

actor ACPSessionRuntimeRegistry {
    private var activations: [SessionRuntimeKey: ACPSessionRuntimeActor] = [:]

    func activation(for key: SessionRuntimeKey) -> ACPSessionRuntimeActor {
        activation(for: key) {
            ACPSessionRuntimeActor(key: key)
        }
    }

    func existingActivation(for key: SessionRuntimeKey) -> ACPSessionRuntimeActor? {
        activations[key]
    }

    func activation(
        for key: SessionRuntimeKey,
        make: @Sendable () -> ACPSessionRuntimeActor
    ) -> ACPSessionRuntimeActor {
        if let existing = activations[key] {
            return existing
        }

        let created = make()
        activations[key] = created
        return created
    }

    func rebuildActivation(for key: SessionRuntimeKey) async -> ACPSessionRuntimeActor {
        await rebuildActivation(for: key) {
            ACPSessionRuntimeActor(key: key)
        }
    }

    func rebuildActivation(
        for key: SessionRuntimeKey,
        make: @Sendable () -> ACPSessionRuntimeActor
    ) async -> ACPSessionRuntimeActor {
        let replacement = make()
        activations[key] = replacement
        return replacement
    }

    func removeActivation(for key: SessionRuntimeKey) async {
        if let activation = activations.removeValue(forKey: key) {
            await activation.close()
        }
    }

    func removeAll(providerReference: ExecutionProviderReference) async {
        let keys = activations.keys.filter { $0.providerReference == providerReference }
        for key in keys {
            if let activation = activations.removeValue(forKey: key) {
                await activation.close()
            }
        }
    }

    func contains(_ key: SessionRuntimeKey) -> Bool {
        activations[key] != nil
    }

    func count(providerReference: ExecutionProviderReference? = nil) -> Int {
        guard let providerReference else {
            return activations.count
        }
        return activations.keys.filter { $0.providerReference == providerReference }.count
    }

    func localSessionIDs(providerReference: ExecutionProviderReference) -> [String] {
        activations.keys
            .filter { $0.providerReference == providerReference }
            .map(\.localSessionID)
    }
}