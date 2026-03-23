import Foundation

struct ACPSessionUpdateRouter: Sendable {
    func shouldProject(
        updateActivationID: RuntimeActivationID,
        currentActivationID: RuntimeActivationID,
        phase: ACPSessionRuntimePhase
    ) -> Bool {
        guard updateActivationID == currentActivationID else {
            return false
        }

        return phase == .sendingTurn
    }

    func shouldConsumeFeatureUpdate(
        updateActivationID: RuntimeActivationID,
        currentActivationID: RuntimeActivationID,
        phase: ACPSessionRuntimePhase
    ) -> Bool {
        guard updateActivationID == currentActivationID else {
            return false
        }

        switch phase {
        case .initializing, .restoring, .ready, .sendingTurn, .cancelling:
            return true
        case .idle, .startingRuntime, .closing, .closed:
            return false
        }
    }
}