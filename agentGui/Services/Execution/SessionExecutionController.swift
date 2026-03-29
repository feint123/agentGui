import Foundation
import Observation

@Observable
@MainActor
final class SessionExecutionController {
    let sessionID: String

    private let projectionStore: ExecutionProjectionStore?
    private var cachedProjection: SessionExecutionProjection

    var projection: SessionExecutionProjection {
        projectionStore?.projection(for: sessionID) ?? cachedProjection
    }

    init(
        sessionID: String,
        projectionStore: ExecutionProjectionStore? = nil,
        initialProjection: SessionExecutionProjection? = nil
    ) {
        self.sessionID = sessionID
        self.projectionStore = projectionStore
        self.cachedProjection = initialProjection ?? projectionStore?.projection(for: sessionID) ?? .empty(sessionID: sessionID)
    }

    func syncFromStore() {
        guard let projectionStore else {
            return
        }

        let latestProjection = projectionStore.projection(for: sessionID)
        guard latestProjection != cachedProjection else {
            return
        }

        cachedProjection = latestProjection
    }
}