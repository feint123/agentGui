import Foundation
import SwiftData
import Testing
@testable import agentGui

struct StoryMemoryModelTests {

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

    @Test func appSettingsExposeStoryMemoryDefaults() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)

        let settings = AppSettings.getOrCreate(in: context)

        #expect(settings.enableStoryMemory == false)
        #expect(settings.storyMemoryAutoExtract == true)
        #expect(settings.storyMemoryPromptBudget == 6)
        #expect(settings.storyMemoryProjectMode == "auto")
    }

    @Test func writingProjectOwnsCoreStoryEntities() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)

        let project = WritingProject(title: "北塔之冬")
        let character = StoryCharacterProfile(name: "林澈")
        let worldRule = StoryWorldRule(title: "禁术需要代价")
        let location = StoryLocationProfile(name: "北塔")
        let style = StoryStyleProfile()

        project.characters.append(character)
        project.worldRules.append(worldRule)
        project.locations.append(location)
        project.styleProfile = style

        context.insert(project)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WritingProject>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.characters.count == 1)
        #expect(fetched.first?.worldRules.count == 1)
        #expect(fetched.first?.locations.count == 1)
        #expect(fetched.first?.styleProfile != nil)
    }

    @Test func chapterSceneTimelineGraphPersists() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)

        let project = WritingProject(title: "北塔之冬")
        let chapter = StoryChapterRecord(number: 1, title: "雾中的灯")
        let scene = StorySceneRecord(title: "抵达王都")
        let event = StoryTimelineEvent(title: "林澈进入王都")
        scene.timelineEventId = event.id.uuidString
        chapter.scenes.append(scene)
        project.chapters.append(chapter)
        project.timelineEvents.append(event)
        context.insert(project)

        let session = Session(title: "写作会话")
        session.activeWritingProjectId = project.id.uuidString
        context.insert(session)
        try context.save()

        let fetchedChapters = try context.fetch(FetchDescriptor<StoryChapterRecord>())
        let fetchedSessions = try context.fetch(FetchDescriptor<Session>())

        #expect(fetchedChapters.first?.scenes.count == 1)
        #expect(fetchedChapters.first?.scenes.first?.timelineEventId == event.id.uuidString)
        #expect(fetchedSessions.first?.activeWritingProjectId == project.id.uuidString)
    }
}