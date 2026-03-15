import Foundation
import Testing
@testable import agentGui

@MainActor
struct OnboardingFlowStateTests {

    @Test func startsOnWelcomeStep() {
        let state = OnboardingFlowState()

        #expect(state.currentStep == .welcome)
        #expect(state.canGoBack == false)
        #expect(state.canAdvance == true)
    }

    @Test func advanceMovesThroughOrderedSteps() {
        let state = OnboardingFlowState()

        state.advance()
        #expect(state.currentStep == .connection)

        state.advance()
        #expect(state.currentStep == .workspace)
        #expect(state.canAdvance == false)
    }

    @Test func goBackReturnsToPreviousStep() {
        let state = OnboardingFlowState()

        state.advance()
        state.advance()
        state.goBack()

        #expect(state.currentStep == .connection)
        #expect(state.canGoBack == true)
    }
}