import Foundation
import Observation

@Observable
@MainActor
final class SessionExecutionRuntimeStateStore {
    private(set) var states: [String: SessionExecutionRuntimeState] = [:]

    func state(for sessionID: String) -> SessionExecutionRuntimeState {
        states[sessionID] ?? .empty(sessionID: sessionID)
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        let sessionID = event.sessionID
        states[sessionID] = SessionExecutionRuntimeStateReducer.reduce(
            current: state(for: sessionID),
            event: event
        )
    }
}