import Foundation
import Testing
@testable import agentGui

struct StoryContinuityServiceTests {

    @Test func continuityServiceFlagsLocationTeleportation() async throws {
        let service = StoryContinuityService()
        let previousScene = StorySceneContinuitySnapshot(
            chapterNumber: 2,
            sceneIndex: 1,
            locationName: "北塔",
            summary: "林澈和顾沉在北塔分开"
        )
        let draft = StorySceneDraftInput(
            chapterNumber: 2,
            sceneIndex: 2,
            title: "雨夜码头",
            summary: "林澈在没有过渡的情况下突然出现在南港码头",
            locationName: "南港码头",
            povCharacterName: "林澈",
            characterNames: ["林澈"],
            referencedForeshadowTags: [],
            text: "林澈站在南港码头，像是刚刚从北塔消失。"
        )
        let cards = [
            StoryCharacterCard(
                name: "林澈",
                summary: "调查者",
                traits: [],
                goals: [],
                speechStyle: "",
                relationships: [:],
                arcStage: "",
                lastSeenChapter: 2,
                lastKnownLocation: "北塔"
            )
        ]

        let warnings = service.evaluateSceneDraft(
            draft: draft,
            previousScene: previousScene,
            activeCharacterCards: cards,
            worldRules: [],
            resolvedForeshadowTags: []
        )

        #expect(warnings.contains { $0.kind == .locationConflict })
    }
}