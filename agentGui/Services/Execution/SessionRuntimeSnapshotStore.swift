import Foundation
import Observation

@Observable
@MainActor
final class SessionRuntimeSnapshotStore {
    private(set) var snapshots: [String: SessionRuntimeSnapshot] = [:]

    var allSnapshots: [SessionRuntimeSnapshot] {
        snapshots.values.sorted { lhs, rhs in
            if lhs.lastUpdatedAt == rhs.lastUpdatedAt {
                return lhs.sessionID < rhs.sessionID
            }
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }
    }

    func snapshot(for sessionID: String) -> SessionRuntimeSnapshot {
        snapshots[sessionID] ?? .empty(sessionID: sessionID)
    }

    func apply(_ event: SessionRuntimeEvent) {
        snapshots[event.sessionID] = SessionRuntimeSnapshotReducer.reduce(
            current: snapshot(for: event.sessionID),
            event: event
        )
    }
}