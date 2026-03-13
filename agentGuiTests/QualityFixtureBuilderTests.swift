import Foundation
import Testing
@testable import agentGui

@MainActor
struct QualityFixtureBuilderTests {

    @Test func parsesKnownUITestArguments() throws {
        let options = TestLaunchOptions(arguments: [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.initialTab", "skills",
            "-com.agentgui.test.preloadApiKey", "true",
            "-com.agentgui.test.preloadMessages", "true",
            "-com.agentgui.test.workflowState", "running",
            "-com.agentgui.test.recoveryMode", "true"
        ])

        #expect(options.isUITestMode)
        #expect(options.initialTab == .skills)
        #expect(options.preloadAPIKey)
        #expect(options.preloadMessages)
        #expect(options.workflowState == .running)
        #expect(options.recoveryMode)
    }

    @Test func invalidWorkflowStateFallsBackSafely() throws {
        let options = TestLaunchOptions(arguments: [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.workflowState", "not-a-real-status",
            "-com.agentgui.test.initialTab", "not-a-real-tab"
        ])

        #expect(options.isUITestMode)
        #expect(options.workflowState == nil)
        #expect(options.initialTab == .chat)
    }

    @Test func recoveryScenarioFixtureBuildsDeterministicRecords() throws {
        let fixture = QualityFixtureBuilder.recoveryScenario(sessionID: "session-recovery")

        #expect(fixture.session.sessionId == "session-recovery")
        #expect(fixture.session.title == "Recovery Drill")
        #expect(fixture.pendingAgentMessage.status == .pending)
        #expect(fixture.pendingAgentMessage.session?.sessionId == fixture.session.sessionId)
        #expect(fixture.workflow.status == .running)
        #expect(fixture.workflow.sessionId == fixture.session.sessionId)
        #expect(fixture.workflow.userTask == "Recover interrupted workflow")
        #expect(fixture.recoverySnapshots.count == 2)
        #expect(fixture.recoverySnapshots.contains { $0.sourceKind == .workflow })
        #expect(fixture.recoverySnapshots.contains { $0.sourceKind == .messageGeneration })
    }

    @Test func inMemoryHarnessSeedsRecoveryScenario() throws {
        let harness = try InMemoryAppHarness.makeRecoveryScenario()

        #expect(harness.launchOptions.isUITestMode)
        #expect(harness.settings.apiKey == "sk-ant-ui-test")

        let summary = try harness.runtimeRecoveryService.loadRecoverySummary(from: harness.context)
        #expect(summary.items.count == 2)
        #expect(summary.items.contains { $0.sourceKind == .workflow })
        #expect(summary.items.contains { $0.sourceKind == .messageGeneration })
    }
}