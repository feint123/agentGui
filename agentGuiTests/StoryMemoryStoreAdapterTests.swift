import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct StoryMemoryStoreAdapterTests {
    private func makeStoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AppSettings.self,
            Session.self,
            WritingProject.self,
            StoryCharacterProfile.self,
            StoryWorldRule.self,
            StoryLocationProfile.self,
            StoryStyleProfile.self,
            StoryChapterRecord.self,
            StorySceneRecord.self,
            StoryTimelineEvent.self,
            StoryForeshadowItem.self,
            StoryContinuityIssue.self,
            configurations: config
        )
    }

    @Test func storyMemoryAdapterMapsCharactersAndRulesToSemanticLayer() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        _ = try service.upsertCharacter(projectId: project.id, payload: StoryCharacterDraft(name: "林澈"))
        _ = try service.upsertWorldRule(
            projectId: project.id,
            payload: StoryWorldRuleDraft(title: "北塔夜禁", detail: "夜禁后不得公开通行")
        )

        let adapter = StoryMemoryStoreAdapter(modelContext: context)
        let records = try adapter.semanticRecords(projectId: project.id)

        #expect(records.contains { $0.layer == .semantic && $0.title == "林澈" })
        #expect(records.contains { $0.layer == .semantic && $0.title == "北塔夜禁" })
    }

    @Test func storyMemoryAdapterSupportsProjectScopedRuntimeReads() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        _ = try service.upsertCharacter(projectId: project.id, payload: StoryCharacterDraft(name: "林澈"))

        let adapter = StoryMemoryStoreAdapter(modelContext: context)
        let records = try adapter.records(for: MemoryScope.project(id: project.id.uuidString))

        #expect(records.contains { $0.title == "林澈" })
        #expect(records.contains { $0.scope == MemoryScope.project(id: project.id.uuidString) })
    }
}