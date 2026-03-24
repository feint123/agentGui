import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentStudioProjectionBuilderTests {
    @Test func rebuildMapsRunningSessionToThinkingCharacter() {
        let builder = AgentStudioProjectionBuilder()
        let session = Session.fixture(title: "Primary")
        session.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue

        let projection = builder.makeProjection(
            sessions: [session],
            execProjections: [
                session.sessionId: SessionExecutionProjection(
                    sessionID: session.sessionId,
                    runningJobID: UUID(),
                    queuedJobIDs: [],
                    queuedCount: 0,
                    isRunning: true,
                    canEditComposer: true,
                    canSubmitNewJob: true,
                    activeProviderID: .builtInAgent,
                    currentPhase: .executing
                )
            ],
            currentToolNames: [:]
        )

        #expect(projection.characters.count == 1)
        #expect(projection.characters[0].animationState == .thinking)
        #expect(projection.characters[0].characterSkin == .coder)
    }

    @Test func rebuildUsesOnlyFirstEightSessions() {
        let builder = AgentStudioProjectionBuilder()
        let sessions = (0..<9).map { index in
            Session.fixture(sessionId: "session-\(index)", title: "Session \(index)")
        }

        let projection = builder.makeProjection(
            sessions: sessions,
            execProjections: [:],
            currentToolNames: [:]
        )

        #expect(projection.characters.count == 8)
        #expect(projection.characters.map(\.id) == Array(sessions.prefix(8)).map(\.sessionId))
    }

    @Test func rebuildUsesCurrentToolNameForReadingStateAndBubble() {
        let builder = AgentStudioProjectionBuilder()
        let session = Session.fixture(title: "Docs")

        let projection = builder.makeProjection(
            sessions: [session],
            execProjections: [
                session.sessionId: SessionExecutionProjection(
                    sessionID: session.sessionId,
                    runningJobID: UUID(),
                    queuedJobIDs: [],
                    queuedCount: 0,
                    isRunning: true,
                    canEditComposer: true,
                    canSubmitNewJob: true,
                    activeProviderID: .builtInAgent,
                    currentPhase: .awaitingToolResults
                )
            ],
            currentToolNames: [session.sessionId: "read_file"]
        )

        let character = projection.characters[0]
        #expect(character.animationState == .reading)
        #expect(character.currentToolName == "read_file")
        #expect(character.speechBubble?.text == "read_file")
    }
}