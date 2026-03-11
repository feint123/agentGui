import Foundation
import Testing
@testable import agentGui

struct BusinessMonitorTests {

    @Test func eventProducesStableCategoryLevelAndSanitizedMetadata() {
        let context = BusinessLogContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: "wf-1",
            roundIndex: 3,
            toolName: "bash",
            phase: "executing"
        )

        let entry = BusinessMonitor.makeEntry(
            .toolExecutionStarted,
            context: context,
            metadata: [
                "command": String(repeating: "x", count: 500),
                "messageCount": 28
            ]
        )

        #expect(entry.category == "AgentBusiness")
        #expect(entry.level == .info)
        #expect(entry.metadata["runID"] as? String == "run-1")
        #expect(entry.metadata["workflowID"] as? String == "wf-1")
        #expect((entry.metadata["command"] as? String)?.count == 160)
        #expect(entry.metadata["messageCount"] as? Int == 28)
    }

    @Test func emitSendsStructuredEntryToSink() {
        let sink = InMemoryBusinessLogSink()
        let context = BusinessLogContext(runID: "run-2", sessionID: "session-2")

        BusinessMonitor.emit(
            .loopStarted,
            context: context,
            metadata: ["modelId": "claude-sonnet-test"],
            sink: sink
        )

        #expect(sink.events.count == 1)
        #expect(sink.events.first?.event == .loopStarted)
        #expect(sink.events.first?.metadata["sessionID"] as? String == "session-2")
    }
}