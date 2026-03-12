import Testing
@testable import agentGui

@MainActor
struct AgentLoopRunnerTests {

    @Test func runnerTypeExistsAsDedicatedOrchestrationBoundary() {
        let _: AgentLoopRunner.Type = AgentLoopRunner.self
    }
}