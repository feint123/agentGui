import Foundation
import Observation

@Observable
@MainActor
final class SessionExecutionRegistry {
    let projectionStore: ExecutionProjectionStore
    private(set) var controllers: [String: SessionExecutionController] = [:]

    @MainActor
    init(projectionStore: ExecutionProjectionStore) {
        self.projectionStore = projectionStore
    }

    @MainActor
    convenience init() {
        self.init(projectionStore: ExecutionProjectionStore())
    }

    func controller(for sessionID: String) -> SessionExecutionController {
        if let controller = controllers[sessionID] {
            return controller
        }

        let controller = SessionExecutionController(
            sessionID: sessionID,
            projectionStore: projectionStore,
            initialProjection: projectionStore.projection(for: sessionID)
        )
        controllers[sessionID] = controller
        return controller
    }

    func projection(for sessionID: String) -> SessionExecutionProjection {
        let controller = controller(for: sessionID)
        controller.syncFromStore()
        return controller.projection
    }

    func setForegroundSession(_ sessionID: String?) {
        for (knownSessionID, controller) in controllers {
            controller.setPresentationState(knownSessionID == sessionID ? .foreground : .background)
        }
    }
}