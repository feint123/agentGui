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

    func removeAll(providerID: ConversationExecutionProviderID) async {
        let keys = activations.keys.filter { $0.providerID == providerID }
        for key in keys {
            if let activation = activations.removeValue(forKey: key) {
                await activation.close()
            }
        }
    }

    func contains(_ key: SessionRuntimeKey) -> Bool {
        activations[key] != nil
    }

    func count(providerID: ConversationExecutionProviderID? = nil) -> Int {
        guard let providerID else {
            return activations.count
        }
        return activations.keys.filter { $0.providerID == providerID }.count
    }

    func localSessionIDs(providerID: ConversationExecutionProviderID) -> [String] {
        activations.keys
            .filter { $0.providerID == providerID }
            .map(\.localSessionID)
    }
}