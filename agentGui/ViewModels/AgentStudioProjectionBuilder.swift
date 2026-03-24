import Foundation
import Observation

@Observable
@MainActor
final class AgentStudioProjectionBuilder {
    private(set) var projection: AgentStudioProjection = .empty

    func rebuild(
        sessions: [Session],
        execProjections: [String: SessionExecutionProjection],
        currentToolNames: [String: String]
    ) {
        projection = makeProjection(
            sessions: sessions,
            execProjections: execProjections,
            currentToolNames: currentToolNames
        )
    }

    func makeProjection(
        sessions: [Session],
        execProjections: [String: SessionExecutionProjection],
        currentToolNames: [String: String]
    ) -> AgentStudioProjection {
        var characters: [AgentCharacterState] = []

        for (index, session) in Array(sessions.prefix(WorkstationSlot.allCases.count)).enumerated() {
            guard let workstation = WorkstationSlot(rawValue: index) else {
                continue
            }

            let executionProjection = execProjections[session.sessionId]
            let toolName = currentToolNames[session.sessionId]
            let animationState = resolveAnimationState(executionProjection: executionProjection, toolName: toolName)

            characters.append(AgentCharacterState(
                id: session.sessionId,
                displayName: String(session.title.prefix(12)),
                characterSkin: session.executionProviderID.defaultCharacterSkin,
                animationState: animationState,
                workstation: workstation,
                speechBubble: makeSpeechBubble(executionProjection: executionProjection, toolName: toolName),
                progressRatio: 0,
                currentToolName: toolName
            ))
        }

        return AgentStudioProjection(
            characters: characters,
            studioTheme: .pixelOffice,
            clockTick: Date()
        )
    }

    private func resolveAnimationState(
        executionProjection: SessionExecutionProjection?,
        toolName: String?
    ) -> CharacterAnimationState {
        guard let executionProjection, executionProjection.isRunning else {
            return .idle
        }

        return CharacterAnimationState.make(
            phase: executionProjection.currentPhase,
            toolName: toolName
        )
    }

    private func makeSpeechBubble(
        executionProjection: SessionExecutionProjection?,
        toolName: String?
    ) -> SpeechBubblePresentation? {
        guard let executionProjection, executionProjection.isRunning else {
            return nil
        }

        if let toolName, !toolName.isEmpty {
            return SpeechBubblePresentation(text: toolName, kind: .action)
        }

        switch executionProjection.currentPhase {
        case .executing:
            return SpeechBubblePresentation(text: "...", kind: .thought)
        case .resumingAfterPause:
            return SpeechBubblePresentation(text: "Resuming", kind: .thought)
        case .finalizing:
            return SpeechBubblePresentation(text: "Done!", kind: .speech)
        case .failed:
            return SpeechBubblePresentation(text: "Error", kind: .speech)
        default:
            return nil
        }
    }
}