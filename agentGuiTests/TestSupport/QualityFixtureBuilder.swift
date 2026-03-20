import Foundation
@testable import agentGui

struct RecoveryScenarioFixture {
    let session: Session
    let pendingAgentMessage: Message
    let recoverySnapshots: [RecoverySnapshot]
}

enum QualityFixtureBuilder {
    @MainActor
    static func recoveryScenario(sessionID: String = "ui-test-session") -> RecoveryScenarioFixture {
        let session = Session.fixture(sessionId: sessionID, title: "Recovery Drill")
        let pendingAgentMessage = Message.agentFixture(
            text: "Partial response that should be recovered",
            session: session,
            status: .pending
        )
        let recoverySnapshots = [
            RecoverySnapshot(
                sessionId: sessionID,
                sourceKind: .messageGeneration,
                sourceIdentifier: pendingAgentMessage.id.uuidString,
                summaryText: "未完成的回复：Partial response that should be recovered",
                metadata: ["messageId": pendingAgentMessage.id.uuidString]
            )
        ]

        return RecoveryScenarioFixture(
            session: session,
            pendingAgentMessage: pendingAgentMessage,
            recoverySnapshots: recoverySnapshots
        )
    }
}