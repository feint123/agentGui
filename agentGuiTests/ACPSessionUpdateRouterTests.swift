import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPSessionUpdateRouterTests {
    @Test func updateRouterDropsStaleActivationUpdates() {
        let router = ACPSessionUpdateRouter()
        let current = RuntimeActivationID(rawValue: UUID())
        let stale = RuntimeActivationID(rawValue: UUID())

        #expect(router.shouldProject(updateActivationID: stale, currentActivationID: current, phase: .sendingTurn) == false)
        #expect(router.shouldConsumeFeatureUpdate(updateActivationID: stale, currentActivationID: current, phase: .restoring) == false)
    }

    @Test func updateRouterAllowsRestoreFeaturesButSuppressesRestoreProjection() {
        let router = ACPSessionUpdateRouter()
        let activationID = RuntimeActivationID(rawValue: UUID())

        #expect(router.shouldConsumeFeatureUpdate(updateActivationID: activationID, currentActivationID: activationID, phase: .restoring))
        #expect(router.shouldProject(updateActivationID: activationID, currentActivationID: activationID, phase: .restoring) == false)
    }

    @Test func updateRouterAllowsLiveProjectionForCurrentActivation() {
        let router = ACPSessionUpdateRouter()
        let activationID = RuntimeActivationID(rawValue: UUID())

        #expect(router.shouldConsumeFeatureUpdate(updateActivationID: activationID, currentActivationID: activationID, phase: .sendingTurn))
        #expect(router.shouldProject(updateActivationID: activationID, currentActivationID: activationID, phase: .sendingTurn))
    }
}