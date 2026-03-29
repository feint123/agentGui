import Foundation

@MainActor
final class SessionRuntimeBus {
    private let store: SessionRuntimeSnapshotStore

    init(store: SessionRuntimeSnapshotStore) {
        self.store = store
    }

    func publish(_ event: SessionRuntimeEvent) {
        store.apply(event)
    }

    func snapshot(for sessionID: String) -> SessionRuntimeSnapshot {
        store.snapshot(for: sessionID)
    }
}