import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct StoryMemoryRetrievalServiceTests {

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

    @Test func storyMemoryServiceCreatesProjectAndAttachesSession() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)

        let project = try service.createProject(title: "北塔之冬", synopsis: "王都迷雾中的权力阴影")
        let session = Session(title: "写作会话")
        context.insert(session)

        try service.attachProject(to: session, projectId: project.id)

        let fetchedProjects = try context.fetch(FetchDescriptor<WritingProject>())
        let fetchedSessions = try context.fetch(FetchDescriptor<Session>())

        #expect(fetchedProjects.count == 1)
        #expect(fetchedProjects.first?.title == "北塔之冬")
        #expect(fetchedSessions.first?.activeWritingProjectId == project.id.uuidString)
    }

    @Test func storyMemoryServiceUpsertsCharactersAndEvents() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(
                name: "林澈",
                summary: "冷静的调查者",
                traits: ["克制", "敏锐"],
                goals: ["找到失踪档案"],
                speechStyle: "短句，少修饰",
                relationships: ["顾沉": "互相试探"],
                arcStage: "怀疑初起",
                lastSeenChapter: 2,
                lastKnownLocation: "王都"
            )
        )

        _ = try service.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(
                name: "顾沉",
                summary: "身份可疑的盟友",
                traits: ["沉稳"],
                goals: ["隐藏真实立场"],
                speechStyle: "礼貌，模糊",
                relationships: ["林澈": "试探合作"],
                arcStage: "秘密潜伏",
                lastSeenChapter: 2,
                lastKnownLocation: "王都"
            )
        )

        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(
                chapterNumber: 1,
                sceneIndex: 1,
                title: "林澈进入王都",
                summary: "主角进入王都调查线索",
                participants: ["林澈"],
                locationName: "王都",
                timeMarker: "黄昏",
                eventType: "arrival",
                foreshadowTags: ["失踪档案"]
            )
        )

        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(
                chapterNumber: 2,
                sceneIndex: 1,
                title: "顾沉现身北塔",
                summary: "顾沉第一次主动接触林澈",
                participants: ["林澈", "顾沉"],
                locationName: "北塔",
                timeMarker: "深夜",
                eventType: "meeting",
                foreshadowTags: ["身份疑云"]
            )
        )

        let fetchedProjects = try context.fetch(FetchDescriptor<WritingProject>())
        #expect(fetchedProjects.first?.characters.count == 2)
        #expect(fetchedProjects.first?.timelineEvents.count == 2)
    }

    @Test func retrievalServiceBuildsStorySlices() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(name: "林澈", summary: "冷静的调查者", goals: ["找到真相"], speechStyle: "短句")
        )
        _ = try service.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(name: "顾沉", summary: "可疑盟友", goals: ["隐藏身份"], speechStyle: "礼貌克制")
        )

        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(chapterNumber: 1, sceneIndex: 1, title: "林澈进入王都", summary: "", participants: ["林澈"], locationName: "王都", timeMarker: "黄昏", eventType: "arrival", foreshadowTags: ["失踪档案"])
        )
        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(chapterNumber: 2, sceneIndex: 1, title: "顾沉现身北塔", summary: "", participants: ["林澈", "顾沉"], locationName: "北塔", timeMarker: "深夜", eventType: "meeting", foreshadowTags: ["身份疑云"])
        )
        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(chapterNumber: 3, sceneIndex: 2, title: "档案残页被发现", summary: "", participants: ["林澈"], locationName: "塔楼密室", timeMarker: "午夜", eventType: "discovery", foreshadowTags: ["旧王朝档案"])
        )

        let foreshadow = StoryForeshadowItem(tag: "失踪档案", introducedInChapter: 1, detail: "档案去向未明")
        project.foreshadowItems.append(foreshadow)
        try context.save()

        let cards = try retrieval.activeCharacterCards(projectId: project.id, names: ["林澈", "顾沉"])
        let foreshadows = try retrieval.unresolvedForeshadows(projectId: project.id, upToChapter: 3)
        let events = try retrieval.recentEvents(projectId: project.id, involving: ["林澈"], limit: 5)

        #expect(cards.count == 2)
        #expect(cards.map(\.name).sorted() == ["林澈", "顾沉"])
        #expect(foreshadows.count == 1)
        #expect(events.count == 3)
        #expect(events.first?.title == "档案残页被发现")
    }
}