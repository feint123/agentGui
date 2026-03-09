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

    @Test func inspectorSnapshotCollectsProjectOverviewAndStats() async throws {
        let project = makeRichProject()

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.overview.title == "北塔之冬")
        #expect(snapshot.overview.synopsis == "王都迷雾中的权力阴影")
        #expect(snapshot.overview.styleSummary == "近距离第三人称 · 保持压抑悬疑感")
        #expect(snapshot.overview.isArchived == true)
        #expect(snapshot.overview.createdAt == Date(timeIntervalSince1970: 100))
        #expect(snapshot.overview.updatedAt == Date(timeIntervalSince1970: 200))

        #expect(snapshot.stats.characterCount == 2)
        #expect(snapshot.stats.chapterCount == 2)
        #expect(snapshot.stats.sceneCount == 3)
        #expect(snapshot.stats.locationCount == 2)
        #expect(snapshot.stats.worldRuleCount == 2)
        #expect(snapshot.stats.timelineEventCount == 2)
        #expect(snapshot.stats.unresolvedForeshadowCount == 2)
        #expect(snapshot.stats.openContinuityIssueCount == 2)
    }

    @Test func inspectorSnapshotBuildsChapterSceneHierarchy() async throws {
        let project = makeRichProject()

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.chapterSections.map(\.number) == [1, 2])
        #expect(snapshot.chapterSections[0].title == "雾中的灯")
        #expect(snapshot.chapterSections[0].sceneCount == 1)
        #expect(snapshot.chapterSections[1].isLocked == true)
        #expect(snapshot.chapterSections[1].summary == "林澈第一次进入北塔内部")
        #expect(snapshot.chapterSections[1].outline == "潜入北塔，确认档案去向")
        #expect(snapshot.chapterSections[1].toneDirective == "压抑、克制")
        #expect(snapshot.chapterSections[1].scenes.map(\.sceneIndex) == [1, 2])
        #expect(snapshot.chapterSections[1].scenes[0].participantNames == ["守卫", "林澈"])
        #expect(snapshot.chapterSections[1].scenes[0].hasPreviousSceneReference == true)
        #expect(snapshot.chapterSections[1].scenes[0].hasTimelineEventReference == true)
        #expect(snapshot.chapterSections[1].scenes[0].contentStatus == "有正文")
        #expect(snapshot.chapterSections[1].scenes[1].contentStatus == "暂无正文")
    }

    @Test func inspectorSnapshotBuildsCharacterLocationRuleAndStyleSections() async throws {
        let project = makeRichProject()

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.characterCards.map(\.name) == ["林澈", "顾沉"])
        #expect(snapshot.characterCards[0].traits == ["冷静", "敏锐"])
        #expect(snapshot.characterCards[0].goals == ["查明真相", "找回档案"])
        #expect(snapshot.characterCards[0].relationshipSummary == ["顾沉: 警惕"])
        #expect(snapshot.locationCards.map(\.name) == ["北塔", "王都"])
        #expect(snapshot.locationCards[0].traits == ["寒冷", "戒备森严"])
        #expect(snapshot.locationCards[0].relatedRules == ["夜禁"])
        #expect(snapshot.locationCards[0].occupants == ["守卫"])
        #expect(snapshot.worldRuleSections.map(\.category) == ["社会秩序", "能力约束"])
        #expect(snapshot.worldRuleSections[0].rules.map(\.title) == ["夜禁"])
        #expect(snapshot.worldRuleSections[1].rules.map(\.relatedEntities) == [["档案官", "密钥"]])
        #expect(snapshot.styleCard?.narrativeVoice == "近距离第三人称")
        #expect(snapshot.styleCard?.authorPreferences == "保持压抑悬疑感")
        #expect(snapshot.styleCard?.samplePassages == ["雾像旧伤一样贴着城墙。"])
        #expect(snapshot.styleCard?.antiPatterns == ["避免现代口语"])
    }

    @Test func inspectorSnapshotGroupsForeshadowsAndContinuityIssuesByStatus() async throws {
        let project = makeRichProject()

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.foreshadowGroups.map(\.status) == ["open", "planned", "resolved"])
        #expect(snapshot.foreshadowGroups[0].items.map(\.tag) == ["失踪档案"])
        #expect(snapshot.foreshadowGroups[1].items.map(\.tag) == ["北塔钥匙"])
        #expect(snapshot.foreshadowGroups[2].items.map(\.tag) == ["黑印戒指"])

        #expect(snapshot.continuityGroups.map(\.status) == ["open", "accepted"])
        #expect(snapshot.continuityGroups[0].items.map(\.issueKind) == ["worldRuleConflict", "locationConflict"])
        #expect(snapshot.continuityGroups[0].items.map(\.severity) == ["critical", "warning"])
        #expect(snapshot.continuityGroups[1].items.map(\.issueKind) == ["characterDrift"])
    }

    @Test func inspectorSnapshotDecodesJSONFieldsIntoReadableLists() async throws {
        let project = makeSparseProject()

        let snapshot = StoryProjectPresentation.inspectorSnapshot(for: project)

        #expect(snapshot.characterCards[0].summary == "基础档案未完善")
        #expect(snapshot.characterCards[0].traits == [])
        #expect(snapshot.characterCards[0].goals == [])
        #expect(snapshot.characterCards[0].relationshipSummary == [])
        #expect(snapshot.locationCards[0].summary == "暂无")
        #expect(snapshot.worldRuleSections[0].rules[0].detail == "暂无")
        #expect(snapshot.chapterSections[0].summary == "暂无")
        #expect(snapshot.chapterSections[0].scenes[0].participantNames == [])
        #expect(snapshot.chapterSections[0].scenes[0].contentStatus == "暂无正文")
        #expect(snapshot.styleCard?.samplePassages == [])
        #expect(snapshot.styleCard?.antiPatterns == [])
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

private extension StoryProjectPresentationTests {
    func makeRichProject() -> WritingProject {
        let project = WritingProject(
            title: "北塔之冬",
            synopsis: "王都迷雾中的权力阴影",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            isArchived: true
        )

        let linChe = StoryCharacterProfile(
            name: "林澈",
            summary: "冷静的调查者",
            traitsJSON: "[\"冷静\",\"敏锐\"]",
            goalsJSON: "[\"查明真相\",\"找回档案\"]",
            speechStyle: "简洁克制",
            relationshipMapJSON: "{\"顾沉\":\"警惕\"}",
            arcStage: "怀疑期",
            lastSeenChapter: 2,
            lastKnownLocation: "北塔"
        )
        let guChen = StoryCharacterProfile(
            name: "顾沉",
            summary: "可疑盟友",
            traitsJSON: "[\"沉默\"]",
            goalsJSON: "[\"隐藏过去\"]",
            speechStyle: "含混",
            relationshipMapJSON: "{\"林澈\":\"试探\"}",
            arcStage: "观察期",
            lastSeenChapter: 2,
            lastKnownLocation: "北塔"
        )
        project.characters.append(linChe)
        project.characters.append(guChen)

        let chapterOne = StoryChapterRecord(
            number: 1,
            title: "雾中的灯",
            outline: "进入王都并得到第一条线索",
            summary: "林澈抵达王都",
            toneDirective: "阴冷",
            isLocked: false
        )
        chapterOne.scenes.append(
            StorySceneRecord(
                title: "进入王都",
                content: "雾像旧伤一样贴着城墙。",
                sceneIndex: 1,
                povCharacterName: "林澈",
                locationName: "王都",
                characterNamesJSON: "[\"林澈\"]",
                summary: "林澈进入王都",
                previousSceneId: "",
                timelineEventId: "event-enter"
            )
        )

        let chapterTwo = StoryChapterRecord(
            number: 2,
            title: "北塔夜访",
            outline: "潜入北塔，确认档案去向",
            summary: "林澈第一次进入北塔内部",
            toneDirective: "压抑、克制",
            isLocked: true
        )
        chapterTwo.scenes.append(
            StorySceneRecord(
                title: "入塔",
                content: "林澈贴着阴影前进。",
                sceneIndex: 1,
                povCharacterName: "林澈",
                locationName: "北塔",
                characterNamesJSON: "[\"守卫\",\"林澈\"]",
                summary: "林澈伪装潜入",
                previousSceneId: "prev-scene",
                timelineEventId: "event-tower"
            )
        )
        chapterTwo.scenes.append(
            StorySceneRecord(
                title: "对峙",
                content: "",
                sceneIndex: 2,
                povCharacterName: "林澈",
                locationName: "北塔顶层",
                characterNamesJSON: "[\"林澈\",\"顾沉\"]",
                summary: "与顾沉正面对峙",
                previousSceneId: "scene-1",
                timelineEventId: ""
            )
        )
        project.chapters.append(chapterTwo)
        project.chapters.append(chapterOne)

        project.locations.append(
            StoryLocationProfile(
                name: "北塔",
                summary: "王都禁区",
                traitsJSON: "[\"寒冷\",\"戒备森严\"]",
                relatedRulesJSON: "[\"夜禁\"]",
                occupantNamesJSON: "[\"守卫\"]"
            )
        )
        project.locations.append(
            StoryLocationProfile(
                name: "王都",
                summary: "权力中枢",
                traitsJSON: "[\"拥挤\"]",
                relatedRulesJSON: "[\"宵禁\"]",
                occupantNamesJSON: "[\"平民\",\"巡逻队\"]"
            )
        )

        project.worldRules.append(
            StoryWorldRule(
                category: "社会秩序",
                title: "夜禁",
                detail: "午夜后平民不得接近北塔",
                scope: "王都内城",
                exceptionsJSON: "[\"持印记者\"]",
                establishedInChapter: 1,
                relatedEntitiesJSON: "[\"北塔\",\"巡逻队\"]",
                mutablePolicy: "immutable"
            )
        )
        project.worldRules.append(
            StoryWorldRule(
                category: "能力约束",
                title: "档案封缄",
                detail: "未经密钥不得拆阅旧档案",
                scope: "北塔档案室",
                exceptionsJSON: "[]",
                establishedInChapter: 2,
                relatedEntitiesJSON: "[\"档案官\",\"密钥\"]",
                mutablePolicy: "conditional"
            )
        )

        project.timelineEvents.append(
            StoryTimelineEvent(
                chapterNumber: 2,
                sceneIndex: 1,
                title: "塔顶对峙",
                summary: "林澈逼近真相",
                participantNamesJSON: "[\"林澈\",\"顾沉\"]",
                locationName: "北塔",
                timeMarker: "午夜",
                eventType: "confrontation",
                foreshadowTagsJSON: "[\"失踪档案\"]",
                isResolved: false,
                supersededByEventId: ""
            )
        )
        project.timelineEvents.append(
            StoryTimelineEvent(
                chapterNumber: 1,
                sceneIndex: 1,
                title: "进入王都",
                summary: "故事正式开始",
                participantNamesJSON: "[\"林澈\"]",
                locationName: "王都",
                timeMarker: "傍晚",
                eventType: "arrival",
                foreshadowTagsJSON: "[]",
                isResolved: true,
                supersededByEventId: "event-tower"
            )
        )

        project.foreshadowItems.append(
            StoryForeshadowItem(
                tag: "失踪档案",
                introducedInChapter: 1,
                detail: "档案去向未明",
                relatedEventIdsJSON: "[\"event-enter\",\"event-tower\"]",
                status: "open"
            )
        )
        project.foreshadowItems.append(
            StoryForeshadowItem(
                tag: "北塔钥匙",
                introducedInChapter: 2,
                detail: "钥匙尚未出现",
                relatedEventIdsJSON: "[]",
                status: "planned"
            )
        )
        project.foreshadowItems.append(
            StoryForeshadowItem(
                tag: "黑印戒指",
                introducedInChapter: 2,
                detail: "已回收",
                relatedEventIdsJSON: "[\"event-tower\"]",
                status: "resolved",
                resolvedInChapter: 2
            )
        )

        project.continuityIssues.append(
            StoryContinuityIssue(
                issueKind: "locationConflict",
                severity: "warning",
                chapterNumber: 1,
                sceneIndex: 1,
                detail: "角色跳转缺少过渡",
                resolutionStatus: "open"
            )
        )
        project.continuityIssues.append(
            StoryContinuityIssue(
                issueKind: "worldRuleConflict",
                severity: "critical",
                chapterNumber: 3,
                sceneIndex: 2,
                detail: "夜禁规则可能被违反",
                resolutionStatus: "open"
            )
        )
        project.continuityIssues.append(
            StoryContinuityIssue(
                issueKind: "characterDrift",
                severity: "warning",
                chapterNumber: 2,
                sceneIndex: 1,
                detail: "顾沉语气偏离设定",
                resolutionStatus: "accepted"
            )
        )

        project.styleProfile = StoryStyleProfile(
            authorPreferences: "保持压抑悬疑感",
            narrativeVoice: "近距离第三人称",
            sentenceLengthMean: 18,
            dialogueRatio: 0.35,
            imageryDensity: 0.6,
            samplePassagesJSON: "[\"雾像旧伤一样贴着城墙。\"]",
            antiPatternsJSON: "[\"避免现代口语\"]"
        )

        return project
    }

    func makeSparseProject() -> WritingProject {
        let project = WritingProject(title: "空白项目", synopsis: "")
        project.characters.append(StoryCharacterProfile(name: "无名者"))

        let chapter = StoryChapterRecord(number: 1, title: "起点")
        chapter.scenes.append(StorySceneRecord(title: "空场", sceneIndex: 1))
        project.chapters.append(chapter)

        project.locations.append(StoryLocationProfile(name: "未命名地点"))
        project.worldRules.append(StoryWorldRule(title: "默认规则"))
        project.styleProfile = StoryStyleProfile()

        return project
    }
}