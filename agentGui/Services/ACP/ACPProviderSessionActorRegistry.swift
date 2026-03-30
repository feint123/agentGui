import Foundation

actor ACPProviderSessionActorRegistry {
    private var actors: [SessionRuntimeKey: ACPProviderSessionActor] = [:]

    func actor(
        for key: SessionRuntimeKey,
        make: @Sendable () -> ACPProviderSessionActor
    ) -> ACPProviderSessionActor {
        if let existing = actors[key] {
            return existing
        }

        let created = make()
        actors[key] = created
        return created
    }

    func existingActor(for key: SessionRuntimeKey) -> ACPProviderSessionActor? {
        actors[key]
    }

    func removeActor(for key: SessionRuntimeKey) {
        actors.removeValue(forKey: key)
    }
}