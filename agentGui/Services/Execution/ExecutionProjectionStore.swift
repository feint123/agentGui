import Foundation
import Observation

@MainActor
protocol SessionExecutionProjectionWriting: AnyObject {
    func projection(for sessionID: String) -> SessionExecutionProjection
    func apply(_ event: SessionExecutionProjectionEvent)
    func apply(runtimeSnapshot: SessionRuntimeSnapshot)
}

extension SessionExecutionProjectionWriting {
    func apply(runtimeSnapshot: SessionRuntimeSnapshot) {}
}

@Observable
@MainActor
final class ExecutionProjectionStore: SessionExecutionProjectionWriting {
    private(set) var projections: [String: SessionExecutionProjection] = [:]

    func apply(_ event: SessionExecutionProjectionEvent) {
        guard case .presentationChanged = event else {
            return
        }

        let sessionID = event.sessionID
        let current = projection(for: sessionID)
        projections[sessionID] = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: event
        )
    }

    func apply(runtimeSnapshot: SessionRuntimeSnapshot) {
        let sessionID = runtimeSnapshot.sessionID
        let current = projection(for: sessionID)
        projections[sessionID] = SessionRuntimeProjectionAdapter.project(
            current: current,
            runtimeSnapshot: runtimeSnapshot
        )
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projections[sessionID] ?? .empty(sessionID: sessionID)
    }
}