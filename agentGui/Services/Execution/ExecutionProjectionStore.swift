import Foundation
import Observation

@Observable
@MainActor
final class ExecutionProjectionStore {
    private(set) var projections: [String: SessionExecutionProjection] = [:]

    func setProjection(_ projection: SessionExecutionProjection) {
        projections[projection.sessionID] = projection
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        projections[sessionID] ?? .empty(sessionID: sessionID)
    }
}