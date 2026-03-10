import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct StoryMemoryDelegationServiceTests {

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

    @Test func delegationClassifierMarksWritingTasksThatNeedMemoryHelp() async throws {
        let container = try makeStoryContainer()
        let service = StoryMemoryDelegationService(modelContext: ModelContext(container))

        let taskType = service.classifyTask(userRequest: "继续写这一章，但先检查顾沉的人设、时间线和伏笔是否一致")

        #expect(taskType == .verifyContinuity)
    }

    @Test func delegationRequestIncludesBoundProjectIdentityAndTaskType() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let storyService = StoryMemoryService(modelContext: context)
        let project = try storyService.createProject(title: "北塔之冬", synopsis: "王都迷雾")
        let session = Session(title: "写作会话")
        context.insert(session)
        try storyService.attachProject(to: session, projectId: project.id)

        let service = StoryMemoryDelegationService(modelContext: context)
        let request = try #require(service.prepareDelegation(session: session, userRequest: "查询林澈和顾沉当前状态").request)

        #expect(request.projectId == project.id.uuidString)
        #expect(request.projectTitle == "北塔之冬")
        #expect(request.taskType == .retrieveContext)
    }

    @Test func delegationRequestUsesContinuityTaskTypeForContinuitySensitivePrompt() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let storyService = StoryMemoryService(modelContext: context)
        let project = try storyService.createProject(title: "北塔之冬", synopsis: "王都迷雾")
        let session = Session(title: "连续性检查")
        context.insert(session)
        try storyService.attachProject(to: session, projectId: project.id)

        let service = StoryMemoryDelegationService(modelContext: context)
        let request = try #require(service.prepareDelegation(session: session, userRequest: "检查这一章时间线和伏笔是否连续").request)

        #expect(request.taskType == .verifyContinuity)
    }

    @Test func delegationServiceReturnsBindingErrorWhenSessionProjectIsMissing() async throws {
        let container = try makeStoryContainer()
        let context = ModelContext(container)
        let session = Session(title: "未绑定会话")
        context.insert(session)

        let service = StoryMemoryDelegationService(modelContext: context)
        let preparation = service.prepareDelegation(session: session, userRequest: "查询角色状态")
        let response = try #require(preparation.preflightResponse)

        #expect(preparation.request == nil)
        #expect(response.status == .projectNotBound)
        #expect(response.risks.map(\.message).contains("当前会话未绑定 WritingProject"))
    }
}