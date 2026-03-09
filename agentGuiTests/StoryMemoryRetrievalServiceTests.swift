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

    @Test func storyMemoryServiceUpsertsChapters() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertChapter(
            projectId: project.id,
            payload: StoryChapterDraft(
                chapterNumber: 3,
                title: "北塔夜访",
                outline: "林澈潜入北塔",
                summary: "第一次进入北塔",
                toneDirective: "压抑",
                isLocked: false
            )
        )
        _ = try service.upsertChapter(
            projectId: project.id,
            payload: StoryChapterDraft(
                chapterNumber: 3,
                title: "北塔夜访",
                outline: "林澈与顾沉对峙",
                summary: "林澈与顾沉首次正面对峙",
                toneDirective: "紧绷",
                isLocked: true
            )
        )

        #expect(project.chapters.count == 1)
        #expect(project.chapters.first?.summary == "林澈与顾沉首次正面对峙")
        #expect(project.chapters.first?.isLocked == true)
    }

    @Test func storyMemoryServiceUpsertsScenesWithinExistingChapter() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertChapter(
            projectId: project.id,
            payload: StoryChapterDraft(chapterNumber: 2, title: "北塔夜访")
        )

        _ = try service.upsertScene(
            projectId: project.id,
            payload: StorySceneDraft(
                chapterNumber: 2,
                sceneIndex: 1,
                title: "入塔",
                content: "林澈潜入北塔。",
                povCharacterName: "林澈",
                locationName: "北塔",
                characterNames: ["林澈"],
                summary: "林澈独自潜入",
                previousSceneId: nil,
                timelineEventId: nil
            )
        )
        _ = try service.upsertScene(
            projectId: project.id,
            payload: StorySceneDraft(
                chapterNumber: 2,
                sceneIndex: 1,
                title: "入塔",
                content: "林澈潜入北塔并发现异常。",
                povCharacterName: "林澈",
                locationName: "北塔",
                characterNames: ["林澈", "顾沉"],
                summary: "林澈发现顾沉也在场",
                previousSceneId: nil,
                timelineEventId: nil
            )
        )

        let chapter = try #require(project.chapters.first)
        #expect(chapter.scenes.count == 1)
        #expect(chapter.scenes.first?.summary == "林澈发现顾沉也在场")
    }

    @Test func storyMemoryServiceRejectsSceneWithoutChapter() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        var didThrow = false
        do {
            _ = try service.upsertScene(
                projectId: project.id,
                payload: StorySceneDraft(chapterNumber: 5, sceneIndex: 1, title: "不存在的章节场景")
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test func storyMemoryServiceUpsertsWorldRules() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertWorldRule(
            projectId: project.id,
            payload: StoryWorldRuleDraft(
                title: "夜禁期间北塔封锁",
                category: "politics",
                detail: "夜禁后北塔不得公开通行",
                scope: "北塔",
                exceptions: ["持令者可入内"],
                establishedInChapter: 2,
                relatedEntities: ["北塔", "城防军"],
                mutablePolicy: "immutable"
            )
        )
        _ = try service.upsertWorldRule(
            projectId: project.id,
            payload: StoryWorldRuleDraft(
                title: "夜禁期间北塔封锁",
                category: "politics",
                detail: "夜禁后只有持令者可进入北塔",
                scope: "北塔",
                exceptions: ["持令者可入内", "王命特赦"],
                establishedInChapter: 2,
                relatedEntities: ["北塔", "城防军"],
                mutablePolicy: "immutable"
            )
        )

        #expect(project.worldRules.count == 1)
        #expect(project.worldRules.first?.detail == "夜禁后只有持令者可进入北塔")
    }

    @Test func storyMemoryServiceUpsertsLocations() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertLocation(
            projectId: project.id,
            payload: StoryLocationDraft(
                name: "北塔",
                summary: "王都北侧的禁区高塔",
                traits: ["封锁", "寒冷"],
                relatedRules: ["夜禁期间北塔封锁"],
                occupantNames: ["顾沉"]
            )
        )
        _ = try service.upsertLocation(
            projectId: project.id,
            payload: StoryLocationDraft(
                name: "北塔",
                summary: "王都北侧的封锁高塔",
                traits: ["封锁", "寒冷", "戒备森严"],
                relatedRules: ["夜禁期间北塔封锁"],
                occupantNames: ["顾沉", "城防军"]
            )
        )

        #expect(project.locations.count == 1)
        #expect(project.locations.first?.summary == "王都北侧的封锁高塔")
    }

    @Test func storyMemoryServiceUpsertsForeshadowsAndResolvesThem() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        let event = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(
                chapterNumber: 1,
                sceneIndex: 1,
                title: "失踪档案被提及",
                foreshadowTags: ["失踪档案"]
            )
        )

        _ = try service.upsertForeshadow(
            projectId: project.id,
            payload: StoryForeshadowDraft(
                tag: "失踪档案",
                introducedInChapter: 1,
                detail: "档案去向未明",
                relatedEventIds: [event.id],
                status: "open",
                resolvedInChapter: 0
            )
        )
        _ = try service.upsertForeshadow(
            projectId: project.id,
            payload: StoryForeshadowDraft(
                tag: "失踪档案",
                introducedInChapter: 1,
                detail: "档案被证实藏在北塔",
                relatedEventIds: [event.id],
                status: "resolved",
                resolvedInChapter: 3
            )
        )

        let openForeshadows = try retrieval.unresolvedForeshadows(projectId: project.id, upToChapter: 3)
        #expect(project.foreshadowItems.count == 1)
        #expect(project.foreshadowItems.first?.status == "resolved")
        #expect(openForeshadows.isEmpty)
    }

    @Test func storyMemoryServiceUpsertsStyleProfileAsSingleton() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertStyleProfile(
            projectId: project.id,
            payload: StoryStyleProfileDraft(
                authorPreferences: "克制，少解释",
                narrativeVoice: "近距离第三人称",
                sentenceLengthMean: 18,
                dialogueRatio: 0.35,
                imageryDensity: 0.4,
                samplePassages: ["夜风像刀一样擦过塔檐。"],
                antiPatterns: ["直白说教"]
            )
        )
        _ = try service.upsertStyleProfile(
            projectId: project.id,
            payload: StoryStyleProfileDraft(
                authorPreferences: "克制，冷硬",
                narrativeVoice: "近距离第三人称",
                sentenceLengthMean: 16,
                dialogueRatio: 0.45,
                imageryDensity: 0.5,
                samplePassages: ["塔影压在街面上，像一条静止的河。"],
                antiPatterns: ["直白说教", "过度抒情"]
            )
        )

        let style = try #require(project.styleProfile)
        #expect(style.authorPreferences == "克制，冷硬")
        let fetched = try context.fetch(FetchDescriptor<StoryStyleProfile>())
        #expect(fetched.count == 1)
    }

    @Test func storyMemoryServiceUpdatesContinuityIssueStatus() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        let issue = StoryContinuityIssue(
            issueKind: "locationConflict",
            severity: "high",
            chapterNumber: 3,
            sceneIndex: 1,
            detail: "地点和上一场景冲突",
            resolutionStatus: "open"
        )
        issue.project = project
        project.continuityIssues.append(issue)
        try context.save()

        _ = try service.updateContinuityIssue(
            projectId: project.id,
            issueId: issue.id,
            payload: StoryContinuityIssueUpdateDraft(
                resolutionStatus: "resolved",
                resolutionNote: "确认该场景发生在次日，问题关闭"
            )
        )

        #expect(project.continuityIssues.count == 1)
        #expect(project.continuityIssues.first?.resolutionStatus == "resolved")
        #expect(project.continuityIssues.first?.detail.contains("resolution_note") == true)
    }

    @Test func retrievalServiceReturnsChapters() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertChapter(projectId: project.id, payload: .init(chapterNumber: 3, title: "北塔夜访"))
        _ = try service.upsertChapter(projectId: project.id, payload: .init(chapterNumber: 1, title: "雾中入城"))

        let chapters = try retrieval.chapters(projectId: project.id)
        #expect(chapters.map(\.number) == [1, 3])
    }

    @Test func retrievalServiceReturnsScenesFilteredByChapter() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertChapter(projectId: project.id, payload: .init(chapterNumber: 2, title: "北塔夜访"))
        _ = try service.upsertChapter(projectId: project.id, payload: .init(chapterNumber: 3, title: "档案残页"))
        _ = try service.upsertScene(projectId: project.id, payload: .init(chapterNumber: 2, sceneIndex: 2, title: "对峙"))
        _ = try service.upsertScene(projectId: project.id, payload: .init(chapterNumber: 2, sceneIndex: 1, title: "入塔"))
        _ = try service.upsertScene(projectId: project.id, payload: .init(chapterNumber: 3, sceneIndex: 1, title: "搜查"))

        let scenes = try retrieval.scenes(projectId: project.id, chapterNumber: 2)
        #expect(scenes.map(\.sceneIndex) == [1, 2])
    }

    @Test func retrievalServiceReturnsWorldRules() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertWorldRule(projectId: project.id, payload: .init(title: "B规则", detail: "后出现"))
        _ = try service.upsertWorldRule(projectId: project.id, payload: .init(title: "A规则", detail: "先出现"))

        let rules = try retrieval.worldRules(projectId: project.id)
        #expect(rules.map(\.title) == ["A规则", "B规则"])
    }

    @Test func retrievalServiceReturnsLocations() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertLocation(projectId: project.id, payload: .init(name: "王都"))
        _ = try service.upsertLocation(projectId: project.id, payload: .init(name: "北塔"))

        let locations = try retrieval.locations(projectId: project.id)
        #expect(locations.map(\.name) == ["北塔", "王都"])
    }

    @Test func retrievalServiceReturnsStyleProfile() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        _ = try service.upsertStyleProfile(
            projectId: project.id,
            payload: .init(authorPreferences: "克制", narrativeVoice: "近距离第三人称")
        )

        let style = try retrieval.styleProfile(projectId: project.id)
        #expect(style?.authorPreferences == "克制")
    }

    @Test func retrievalServiceReturnsContinuityIssuesByStatus() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let service = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")

        let openIssue = StoryContinuityIssue(issueKind: "locationConflict", severity: "high", chapterNumber: 3, sceneIndex: 1, detail: "open", resolutionStatus: "open")
        openIssue.project = project
        let resolvedIssue = StoryContinuityIssue(issueKind: "worldRuleConflict", severity: "medium", chapterNumber: 2, sceneIndex: 1, detail: "resolved", resolutionStatus: "resolved")
        resolvedIssue.project = project
        project.continuityIssues.append(openIssue)
        project.continuityIssues.append(resolvedIssue)
        try context.save()

        let openIssues = try retrieval.continuityIssues(projectId: project.id, resolutionStatus: "open")
        #expect(openIssues.count == 1)
        #expect(openIssues.first?.issueKind == "locationConflict")
    }
}