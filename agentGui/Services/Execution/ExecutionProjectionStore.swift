import Foundation
import Observation

@MainActor
protocol SessionExecutionProjectionWriting: AnyObject {
    func projection(for sessionID: String) -> SessionExecutionProjection
    func apply(_ event: SessionExecutionProjectionEvent)
}

@Observable
@MainActor
final class ExecutionProjectionStore: SessionExecutionProjectionWriting {
    private(set) var projections: [String: SessionExecutionProjection] = [:]

    func setProjection(_ projection: SessionExecutionProjection) {
        projections[projection.sessionID] = projection
    }

    func apply(_ event: SessionExecutionProjectionEvent) {
        let sessionID = event.sessionID
        let current = projection(for: sessionID)
        projections[sessionID] = SessionExecutionProjectionReducer.reduce(
            current: current,
            event: event
        )
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projections[sessionID] ?? .empty(sessionID: sessionID)
    }
}