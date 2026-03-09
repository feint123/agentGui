import Foundation
import Testing
@testable import agentGui

struct StoryProjectPresentationTests {

    @Test func projectSummariesPreferRecentlyUpdatedAndMarkActiveBinding() async throws {
        let older = WritingProject(
            title: "旧都回声",
            synopsis: "旧城阴影",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        older.characters.append(StoryCharacterProfile(name: "季衡"))
        older.foreshadowItems.append(StoryForeshadowItem(tag: "钟楼密钥", introducedInChapter: 1, status: "open"))

        let newer = WritingProject(
            title: "北塔之冬",
            synopsis: "王都迷雾中的权力阴影",
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        newer.characters.append(StoryCharacterProfile(name: "林澈"))
        newer.characters.append(StoryCharacterProfile(name: "顾沉"))
        newer.foreshadowItems.append(StoryForeshadowItem(tag: "失踪档案", introducedInChapter: 1, status: "open"))
        newer.foreshadowItems.append(StoryForeshadowItem(tag: "旧王朝印记", introducedInChapter: 2, status: "resolved", resolvedInChapter: 3))
        newer.continuityIssues.append(StoryContinuityIssue(issueKind: "locationConflict", detail: "角色跳转缺少过渡"))

        let summaries = StoryProjectPresentation.summaries(
            projects: [older, newer],
            activeProjectId: newer.id
        )

        #expect(summaries.map(\.title) == ["北塔之冬", "旧都回声"])
        #expect(summaries.first?.isActive == true)
        #expect(summaries.first?.characterCount == 2)
        #expect(summaries.first?.unresolvedForeshadowCount == 1)
        #expect(summaries.first?.openContinuityIssueCount == 1)
        #expect(summaries.last?.isActive == false)
    }

    @Test func inspectorSnapshotCollectsProjectHighlights() async throws {
        let project = WritingProject(title: "北塔之冬", synopsis: "王都迷雾中的权力阴影")
        project.styleProfile = StoryStyleProfile(
            authorPreferences: "保持压抑悬疑感",
            narrativeVoice: "近距离第三人称"
        )
        project.characters.append(StoryCharacterProfile(name: "林澈", summary: "冷静的调查者"))
        project.characters.append(StoryCharacterProfile(name: "顾沉", summary: "可疑盟友"))
        project.chapters.append(StoryChapterRecord(number: 1, title: "雾中的灯"))
        project.chapters.append(StoryChapterRecord(number: 2, title: "北塔夜访"))
        project.timelineEvents.append(StoryTimelineEvent(chapterNumber: 2, sceneIndex: 1, title: "塔顶对峙", locationName: "北塔"))
        project.timelineEvents.append(StoryTimelineEvent(chapterNumber: 1, sceneIndex: 1, title: "进入王都", locationName: "王都"))
        project.foreshadowItems.append(StoryForeshadowItem(tag: "失踪档案", introducedInChapter: 1, detail: "档案去向未明", status: "open"))
        project.foreshadowItems.append(StoryForeshadowItem(tag: "黑印戒指", introducedInChapter: 2, detail: "已回收", status: "resolved", resolvedInChapter: 2))
        project.continuityIssues.append(StoryContinuityIssue(issueKind: "worldRuleConflict", detail: "夜禁规则可能被违反"))

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.title == "北塔之冬")
        #expect(snapshot.characterNames == ["林澈", "顾沉"])
        #expect(snapshot.chapterTitles == ["第 1 章 · 雾中的灯", "第 2 章 · 北塔夜访"])
        #expect(snapshot.timelineTitles == ["Ch1 Sc1 · 进入王都", "Ch2 Sc1 · 塔顶对峙"])
        #expect(snapshot.unresolvedForeshadowTags == ["失踪档案"])
        #expect(snapshot.openContinuityIssues == ["worldRuleConflict · 夜禁规则可能被违反"])
        #expect(snapshot.styleSummary == "近距离第三人称 · 保持压抑悬疑感")
    }

    @Test func summariesExcludeOnlyResolvedContinuityIssues() async throws {
        let project = WritingProject(title: "北塔之冬", synopsis: "王都迷雾中的权力阴影")
        project.continuityIssues.append(
            StoryContinuityIssue(issueKind: "locationConflict", detail: "未处理", resolutionStatus: "open")
        )
        project.continuityIssues.append(
            StoryContinuityIssue(issueKind: "characterDrift", detail: "接受偏差", resolutionStatus: "accepted")
        )
        project.continuityIssues.append(
            StoryContinuityIssue(issueKind: "worldRuleConflict", detail: "已关闭", resolutionStatus: "resolved")
        )

        let summaries = StoryProjectPresentation.summaries(projects: [project], activeProjectId: nil)

        #expect(summaries.first?.openContinuityIssueCount == 2)
    }
}