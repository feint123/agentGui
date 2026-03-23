import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPSessionRuntimeStateMachineTests {
    @Test func sessionRuntimeKeyHashesProviderAndLocalSessionTogether() {
        let left = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-1")
        let right = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-1")
        let otherProvider = SessionRuntimeKey(providerID: .openCodeCLI, localSessionID: "session-1")

        #expect(left == right)
        #expect(left != otherProvider)
        #expect(Set([left, right, otherProvider]).count == 2)
    }

    @Test func runtimeActivationIDDefaultsToUniqueValues() {
        let first = RuntimeActivationID()
        let second = RuntimeActivationID()

        #expect(first != second)
    }

    @Test func stateMachineAcceptsNominalActivationFlow() throws {
        var machine = ACPSessionRuntimeStateMachine()

        try machine.transition(.startRuntime)
        try machine.transition(.runtimeStarted)
        try machine.transition(.beginRestore)
        try machine.transition(.finishRestore)
        try machine.transition(.beginPrompt)
        try machine.transition(.finishPrompt)

        #expect(machine.phase == .ready)
    }

    @Test func stateMachineAllowsReadyWithoutRestoreReplay() throws {
        var machine = ACPSessionRuntimeStateMachine()

        try machine.transition(.startRuntime)
        try machine.transition(.runtimeStarted)
        try machine.transition(.finishRestore)

        #expect(machine.phase == .ready)
    }

    @Test func stateMachineRejectsPromptBeforeReady() {
        var machine = ACPSessionRuntimeStateMachine()

        #expect(throws: ACPSessionRuntimeStateMachine.Error.self) {
            try machine.transition(.beginPrompt)
        }
    }
}