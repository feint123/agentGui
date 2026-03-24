import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentStudioSceneDiffTests {
	@Test func applyProjectionReusesExistingCharacterNode() throws {
		let scene = AgentStudioScene()
		let initial = makeProjection(
			characters: [
				makeCharacter(id: "session-1", state: .thinking)
			]
		)

		scene.applyProjection(initial)

		let firstNode = try #require(scene.characterNode(for: "session-1"))

		let updated = makeProjection(
			characters: [
				makeCharacter(id: "session-1", state: .reading, toolName: "read_file")
			]
		)

		scene.applyProjection(updated)

		let reusedNode = try #require(scene.characterNode(for: "session-1"))
		#expect(ObjectIdentifier(firstNode) == ObjectIdentifier(reusedNode))
		#expect(reusedNode.renderedAnimationState == .reading)
		#expect(reusedNode.renderedToolName == "read_file")
		#expect(scene.renderedCharacterIDs == ["session-1"])
	}

	@Test func applyProjectionRemovesStaleCharacterNodes() {
		let scene = AgentStudioScene()
		scene.applyProjection(makeProjection(characters: [makeCharacter(id: "session-1", state: .idle)]))

		scene.applyProjection(makeProjection(characters: []))

		#expect(scene.characterNode(for: "session-1") == nil)
		#expect(scene.renderedCharacterIDs.isEmpty)
	}

	private func makeProjection(characters: [AgentCharacterState]) -> AgentStudioProjection {
		AgentStudioProjection(characters: characters, studioTheme: .pixelOffice, clockTick: Date())
	}

	private func makeCharacter(
		id: String,
		state: CharacterAnimationState,
		toolName: String? = nil,
		workstation: WorkstationSlot = .slot1
	) -> AgentCharacterState {
		AgentCharacterState(
			id: id,
			displayName: "Agent",
			characterSkin: .coder,
			animationState: state,
			workstation: workstation,
			speechBubble: toolName.map { SpeechBubblePresentation(text: $0, kind: .action) },
			progressRatio: 0,
			currentToolName: toolName
		)
	}
}
