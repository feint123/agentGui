import Foundation
import SwiftData
import SwiftAnthropic
import Testing
@testable import agentGui

@MainActor
struct StoryMemoryPromptAssemblerTests {

    private func makeStringArray(_ values: [String]) -> MessageResponse.Content.DynamicContent {
        .array(values.map(MessageResponse.Content.DynamicContent.string))
    }

    private func toolNames(from tools: [MessageParameter.Tool]) -> Set<String> {
        Set(tools.compactMap(toolName(from:)))
    }

    private func toolName(from tool: MessageParameter.Tool) -> String? {
        extractString(labeled: "name", from: Mirror(reflecting: tool))
    }

    private func extractString(labeled target: String, from mirror: Mirror) -> String? {
        for child in mirror.children {
            if child.label == target, let value = child.value as? String {
                return value
            }

            let childMirror = Mirror(reflecting: child.value)
            if let value = extractString(labeled: target, from: childMirror) {
                return value
            }
        }

        return nil
    }

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

    @Test func promptAssemblerBuildsCompactWritingContext() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let storyService = StoryMemoryService(modelContext: context)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let assembler = StoryMemoryPromptAssembler(modelContext: context, retrievalService: retrieval)

        let project = try storyService.createProject(title: "北塔之冬", synopsis: "王都迷雾中的权力阴影")
        project.styleProfile = StoryStyleProfile(
            authorPreferences: "保持压抑悬疑感",
            narrativeVoice: "近距离第三人称",
            samplePassagesJSON: StoryMemoryJSONCodec.encode(["风从塔窗里灌进来，像迟来的警告"]),
            antiPatternsJSON: StoryMemoryJSONCodec.encode(["避免解释性独白"])
        )
        project.worldRules.append(
            StoryWorldRule(
                category: "politics",
                title: "夜禁期间北塔封锁",
                detail: "夜禁后北塔不得公开通行，只有持令者可入内",
                scope: "王都北塔"
            )
        )

        _ = try storyService.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(
                name: "林澈",
                summary: "冷静的调查者",
                goals: ["找到真相"],
                speechStyle: "短句",
                arcStage: "怀疑升高",
                lastSeenChapter: 2,
                lastKnownLocation: "北塔"
            )
        )
        _ = try storyService.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(
                name: "顾沉",
                summary: "可疑盟友",
                goals: ["隐藏身份"],
                speechStyle: "礼貌克制",
                arcStage: "秘密潜伏",
                lastSeenChapter: 2,
                lastKnownLocation: "北塔"
            )
        )

        let chapter2 = StoryChapterRecord(number: 2, title: "北塔夜访")
        let previousScene = StorySceneRecord(
            title: "塔顶对峙",
            sceneIndex: 2,
            povCharacterName: "林澈",
            locationName: "北塔",
            summary: "林澈第一次注意到顾沉刻意回避旧档案的话题"
        )
        chapter2.scenes.append(previousScene)
        project.chapters.append(chapter2)

        _ = try storyService.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(
                chapterNumber: 2,
                sceneIndex: 2,
                title: "塔顶对峙",
                summary: "顾沉回避旧档案来源",
                participants: ["林澈", "顾沉"],
                locationName: "北塔",
                timeMarker: "深夜",
                eventType: "conflict",
                foreshadowTags: ["失踪档案"]
            )
        )
        project.foreshadowItems.append(
            StoryForeshadowItem(tag: "失踪档案", introducedInChapter: 1, detail: "档案去向未明")
        )
        try context.save()

        let slice = try assembler.buildWritingSlice(
            projectId: project.id,
            chapterNumber: 3,
            currentSceneGoal: "写出林澈第一次怀疑顾沉的瞬间",
            activeCharacters: ["林澈", "顾沉"],
            promptBudget: 4
        )

        #expect(slice.contains("当前写作目标"))
        #expect(slice.contains("上一场景衔接"))
        #expect(slice.contains("活跃角色"))
        #expect(slice.contains("适用规则"))
        #expect(slice.contains("相关事件"))
        #expect(slice.contains("未解决伏笔"))
        #expect(slice.contains("风格指令"))
        #expect(slice.contains("林澈第一次怀疑顾沉的瞬间"))
        #expect(slice.contains("塔顶对峙"))
        #expect(slice.contains("失踪档案"))

        let goalRange = try #require(slice.range(of: "当前写作目标"))
        let previousSceneRange = try #require(slice.range(of: "上一场景衔接"))
        let charactersRange = try #require(slice.range(of: "活跃角色"))
        let rulesRange = try #require(slice.range(of: "适用规则"))
        let eventsRange = try #require(slice.range(of: "相关事件"))
        let foreshadowRange = try #require(slice.range(of: "未解决伏笔"))
        let styleRange = try #require(slice.range(of: "风格指令"))

        #expect(goalRange.lowerBound < previousSceneRange.lowerBound)
        #expect(previousSceneRange.lowerBound < charactersRange.lowerBound)
        #expect(charactersRange.lowerBound < rulesRange.lowerBound)
        #expect(rulesRange.lowerBound < eventsRange.lowerBound)
        #expect(eventsRange.lowerBound < foreshadowRange.lowerBound)
        #expect(foreshadowRange.lowerBound < styleRange.lowerBound)
    }

    @Test func toolBuilderOmitsRawStoryMemoryToolsFromMainAgentByDefault() async throws {
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let names = toolNames(from: tools)

        #expect(names.contains("run_subagent"))
        #expect(!names.contains("story_memory_query"))
        #expect(!names.contains("story_memory_upsert_character"))
        #expect(!names.contains("story_memory_verify_continuity"))
    }

    @Test func toolBuilderKeepsRunSubagentAvailableForMemoryDelegation() async throws {
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let names = toolNames(from: tools)

        #expect(names.contains("run_subagent"))
    }

    @Test func systemPromptUsesDelegationProtocolInsteadOfPermanentStoryMemoryRules() async throws {
        let settings = AppSettings()
        settings.enableStoryMemory = true
        let session = Session(title: "写作会话")
        session.activeWritingProjectId = UUID().uuidString

        let prompt = ClaudeService().makeSystemPromptForTests(
            skills: [],
            workingDirectory: "/tmp/project",
            settings: settings,
            session: session
        )

        #expect(prompt.contains("run_subagent"))
        #expect(prompt.contains("creative_memory_manager"))
        #expect(prompt.contains("按需委托"))
        #expect(!prompt.contains("Use structured story memory tools when available instead of collapsing these facts into generic notes."))
    }

    @Test func workflowRoleRegistryIncludesCreativeMemoryManager() async throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "creative_memory_manager"))

        #expect(role.enableTextEditor == false)
        #expect(role.enableBash == false)
        #expect(role.enableStoryMemoryTools == true)
    }

    @Test func memoryRoleBuildsSubagentToolsWithStoryMemoryCapabilities() async throws {
        let settings = AppSettings()
        settings.enableStoryMemory = true
        let role = try #require(WorkflowRoleDefinition.find(named: "creative_memory_manager"))

        let tools = ClaudeService().makeSubagentToolsForTests(modelId: "claude-sonnet-4-6", definition: role, settings: settings)
        let names = toolNames(from: tools)

        #expect(names.contains("story_memory_query"))
        #expect(names.contains("story_memory_verify_continuity"))
        #expect(names.contains("story_memory_upsert_character"))
    }

    @Test func memoryRoleDoesNotExposeGeneralWriteCodeToolsByDefault() async throws {
        let settings = AppSettings()
        settings.enableStoryMemory = true
        let role = try #require(WorkflowRoleDefinition.find(named: "creative_memory_manager"))

        let tools = ClaudeService().makeSubagentToolsForTests(modelId: "claude-sonnet-4-6", definition: role, settings: settings)
        let names = toolNames(from: tools)

        #expect(!names.contains("bash"))
        #expect(!names.contains("str_replace_based_edit_tool"))
    }

    @Test func agentLoopDoesNotInjectStoryMemoryBootstrapForNonMemoryTasks() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let storyService = StoryMemoryService(modelContext: context)
        let project = try storyService.createProject(title: "北塔之冬", synopsis: "王都迷雾")
        let session = Session(title: "普通会话")
        context.insert(session)
        try storyService.attachProject(to: session, projectId: project.id)

        let bootstrap = try ClaudeService().makeStoryMemoryBootstrapForTests(
            settings: settings,
            sessionId: session.sessionId,
            messages: [MessageParameter.Message(role: .user, content: .text("把下面这段话压缩成两句"))],
            modelContext: context
        )

        #expect(bootstrap == nil)
    }

    @Test func promptAssemblerCanFormatMinimalTaskScopedSliceFromDelegationResponse() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let retrieval = StoryMemoryRetrievalService(modelContext: context)
        let assembler = StoryMemoryPromptAssembler(modelContext: context, retrievalService: retrieval)
        let request = StoryMemoryDelegationRequest(
            projectId: UUID().uuidString,
            projectTitle: "北塔之冬",
            taskType: .verifyContinuity,
            userRequest: "检查顾沉和林澈在北塔这场戏是否与之前设定冲突",
            candidateText: nil
        )
        let response = StoryMemoryDelegationResponse(
            status: .ready,
            taskType: .verifyContinuity,
            facts: [StoryMemoryFactSlice(title: "角色位置", detail: "林澈和顾沉上次都在北塔", source: "timeline")],
            inferences: ["这场戏应延续紧张对峙气氛"],
            risks: [StoryMemoryRiskItem(level: .warning, message: "若顾沉突然离开王都，会与上一章冲突", needsUserConfirmation: false)],
            writeDecision: nil,
            fallbackNote: nil
        )

        let slice = assembler.buildDelegatedSlice(request: request, response: response)

        #expect(slice.contains("当前任务"))
        #expect(slice.contains("已确认事实"))
        #expect(slice.contains("推断"))
        #expect(slice.contains("风险"))
        #expect(slice.contains("若顾沉突然离开王都，会与上一章冲突"))
    }

    @Test func storyMemoryToolsQueryAndVerifyContinuity() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        let session = Session(title: "写作会话")
        context.insert(session)
        try service.attachProject(to: session, projectId: project.id)

        _ = try service.upsertCharacter(
            projectId: project.id,
            payload: StoryCharacterDraft(
                name: "林澈",
                summary: "冷静的调查者",
                goals: ["找到真相"],
                speechStyle: "短句",
                lastSeenChapter: 2,
                lastKnownLocation: "北塔"
            )
        )

        _ = try service.appendTimelineEvent(
            projectId: project.id,
            payload: StoryTimelineEventDraft(
                chapterNumber: 2,
                sceneIndex: 2,
                title: "塔顶对峙",
                summary: "顾沉回避旧档案来源",
                participants: ["林澈", "顾沉"],
                locationName: "北塔",
                timeMarker: "深夜",
                eventType: "conflict",
                foreshadowTags: ["失踪档案"]
            )
        )

        let chapter = StoryChapterRecord(number: 2, title: "北塔夜访")
        chapter.scenes.append(
            StorySceneRecord(
                title: "塔顶对峙",
                sceneIndex: 2,
                povCharacterName: "林澈",
                locationName: "北塔",
                summary: "林澈逼问顾沉档案来源"
            )
        )
        project.chapters.append(chapter)
        project.worldRules.append(
            StoryWorldRule(
                category: "politics",
                title: "夜禁期间北塔封锁",
                detail: "夜禁后北塔不得公开通行，只有持令者可入内",
                scope: "北塔"
            )
        )
        project.foreshadowItems.append(
            StoryForeshadowItem(tag: "失踪档案", introducedInChapter: 1, detail: "档案去向未明", status: "resolved", resolvedInChapter: 2)
        )
        try context.save()

        let claudeService = ClaudeService()
        let queryResult = await claudeService.executeTool(
            name: "story_memory_query",
            input: [
                "query_kind": .string("events"),
                "involving": makeStringArray(["林澈"]),
                "limit": .integer(3)
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(queryResult.status == .success)
        #expect(queryResult.text.contains("塔顶对峙"))
        #expect(queryResult.text.contains("相关事件"))

        let continuityResult = await claudeService.executeTool(
            name: "story_memory_verify_continuity",
            input: [
                "chapter_number": .integer(2),
                "scene_index": .integer(1),
                "title": .string("北塔再入"),
                "summary": .string("林澈再次进入北塔查档"),
                "location_name": .string("王都内城 北塔"),
                "pov_character_name": .string("林澈"),
                "character_names": makeStringArray(["林澈"]),
                "referenced_foreshadow_tags": makeStringArray(["失踪档案"]),
                "text": .string("夜禁后，林澈再次进入北塔寻找线索。")
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(continuityResult.status == .success)
        #expect(continuityResult.text.contains("Continuity warnings"))
        #expect(continuityResult.text.contains("locationConflict"))
        #expect(continuityResult.text.contains("chapterRegression"))
        #expect(continuityResult.text.contains("resolvedForeshadowReuse"))
        #expect(continuityResult.text.contains("worldRuleConflict"))
    }

    @Test func storyMemoryToolsUpsertAndQueryExtendedKinds() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        let session = Session(title: "写作会话")
        context.insert(session)
        try service.attachProject(to: session, projectId: project.id)

        let claudeService = ClaudeService()

        let chapterResult = await claudeService.executeTool(
            name: "story_memory_upsert_chapter",
            input: [
                "chapter_number": .integer(3),
                "title": .string("北塔夜访"),
                "summary": .string("林澈夜探北塔")
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(chapterResult.status == .success)
        #expect(chapterResult.text.contains("created") || chapterResult.text.contains("updated"))
        #expect(chapterResult.text.contains("北塔之冬"))

        let sceneResult = await claudeService.executeTool(
            name: "story_memory_upsert_scene",
            input: [
                "chapter_number": .integer(3),
                "scene_index": .integer(1),
                "title": .string("入塔"),
                "summary": .string("林澈进入北塔"),
                "character_names": makeStringArray(["林澈"])
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(sceneResult.status == .success)

        let worldRuleResult = await claudeService.executeTool(
            name: "story_memory_upsert_world_rule",
            input: [
                "title": .string("夜禁期间北塔封锁"),
                "category": .string("politics"),
                "detail": .string("夜禁后北塔不得公开通行")
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(worldRuleResult.status == .success)

        let styleResult = await claudeService.executeTool(
            name: "story_memory_upsert_style_profile",
            input: [
                "author_preferences": .string("克制，冷硬"),
                "narrative_voice": .string("近距离第三人称")
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(styleResult.status == .success)

        let chaptersQuery = await claudeService.executeTool(
            name: "story_memory_query",
            input: ["query_kind": .string("chapters")],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(chaptersQuery.status == .success)
        #expect(chaptersQuery.text.contains("北塔夜访"))

        let rulesQuery = await claudeService.executeTool(
            name: "story_memory_query",
            input: ["query_kind": .string("world_rules")],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(rulesQuery.status == .success)
        #expect(rulesQuery.text.contains("夜禁期间北塔封锁"))

        let styleQuery = await claudeService.executeTool(
            name: "story_memory_query",
            input: ["query_kind": .string("style")],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(styleQuery.status == .success)
        #expect(styleQuery.text.contains("近距离第三人称"))
    }

    @Test func storyMemoryToolUpdatesContinuityIssueStatus() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let settings = AppSettings()
        settings.enableStoryMemory = true

        let service = StoryMemoryService(modelContext: context)
        let project = try service.createProject(title: "北塔之冬", synopsis: "")
        let session = Session(title: "写作会话")
        context.insert(session)
        try service.attachProject(to: session, projectId: project.id)

        let issue = StoryContinuityIssue(
            issueKind: "locationConflict",
            severity: "high",
            chapterNumber: 3,
            sceneIndex: 1,
            detail: "地点冲突",
            resolutionStatus: "open"
        )
        issue.project = project
        project.continuityIssues.append(issue)
        try context.save()

        let result = await ClaudeService().executeTool(
            name: "story_memory_update_continuity_issue",
            input: [
                "issue_id": .string(issue.id.uuidString),
                "resolution_status": .string("resolved"),
                "resolution_note": .string("确认发生在次日，关闭问题")
            ],
            settings: settings,
            session: session,
            modelContext: context
        )

        #expect(result.status == .success)
        #expect(result.text.contains("resolved"))
        #expect(project.continuityIssues.first?.resolutionStatus == "resolved")
    }
}