import Testing
@testable import agentGui

@MainActor
struct AgentStudioProjectionMappingTests {
	@Test func readingToolsMapToReadingAnimation() {
		#expect(CharacterAnimationState.make(phase: .awaitingToolResults, toolName: "read_file") == .reading)
		#expect(CharacterAnimationState.make(phase: .awaitingToolResults, toolName: "查看项目结构") == .reading)
	}

	@Test func nonReadingToolsMapToTypingAnimation() {
		#expect(CharacterAnimationState.make(phase: .awaitingToolResults, toolName: "run_in_terminal") == .typing)
		#expect(CharacterAnimationState.make(phase: .continuingTruncatedResponse, toolName: nil) == .typing)
	}

	@Test func characterAtlasNameMatchesSkinAndAnimationState() {
		#expect(AgentCharacterNode.atlasName(for: .wizard, state: .thinking) == "wizard_thinking")
		#expect(AgentCharacterNode.atlasName(for: .robot, state: .reading) == "robot_reading")
	}

	@Test func officeLayoutUsesOfficeSpriteAssets() {
		let assets = Set(AgentStudioScene.officeAssetNames)

		#expect(assets.contains("desk"))
		#expect(assets.contains("chair"))
		#expect(assets.contains("bookshelf"))
		#expect(assets.contains("wall_clock"))
		#expect(assets.contains("big_plant"))
	}
}
