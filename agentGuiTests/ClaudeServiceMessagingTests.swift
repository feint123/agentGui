import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ClaudeServiceMessagingTests {

    @Test func sendMessageDoesNotDuplicatePersistedCurrentUserInAPIContext() async throws {
        let claudeService = ClaudeService()
        let fakeService = CapturingAnthropicService()
        let modelContext = try makeModelContext()
        let session = Session.fixture(title: "Existing Session")

        let olderUser = Message.userFixture(text: "上一条消息", session: session)
        let olderAgent = Message.agentFixture(text: "上一条回复", session: session)
        let currentUser = Message.userFixture(text: "放松一下", session: session)

        modelContext.insert(AppSettings.testFixture(apiKey: "sk-ant-test"))
        modelContext.insert(session)
        modelContext.insert(olderUser)
        modelContext.insert(olderAgent)
        modelContext.insert(currentUser)
        try modelContext.save()

        claudeService.service = fakeService

        do {
            try await claudeService.sendMessage(
                text: "放松一下",
                session: session,
                modelId: "claude-test",
                modelContext: modelContext
            )
            Issue.record("Expected sendMessage to fail after the fake service captured the request")
        } catch {
            // Expected: the fake service aborts after capturing the outgoing parameter.
        }

        let captured = try #require(fakeService.capturedMessageParameter)
        let userTexts = captured.messages
            .filter { $0.role == "user" }
            .map { claudeService.extractText(from: $0.content) }

        let previousMessageOccurrences = userTexts.filter { $0 == "上一条消息" }.count
        let currentMessageOccurrences = userTexts.filter { $0 == "放松一下" }.count

        if currentMessageOccurrences != 1 || previousMessageOccurrences != 1 {
            Issue.record("Captured user texts: \(userTexts)")
        }

        #expect(previousMessageOccurrences == 1)
        #expect(currentMessageOccurrences == 1)
    }

    @Test func sendMessageAppendsCurrentUserWhenCallerHasNotPersistedItYet() async throws {
        let claudeService = ClaudeService()
        let fakeService = CapturingAnthropicService()
        let modelContext = try makeModelContext()
        let session = Session.fixture(title: "Existing Session")

        let olderUser = Message.userFixture(text: "上一条消息", session: session)
        let olderAgent = Message.agentFixture(text: "上一条回复", session: session)

        modelContext.insert(AppSettings.testFixture(apiKey: "sk-ant-test"))
        modelContext.insert(session)
        modelContext.insert(olderUser)
        modelContext.insert(olderAgent)
        try modelContext.save()

        claudeService.service = fakeService

        do {
            try await claudeService.sendMessage(
                text: "放松一下",
                session: session,
                modelId: "claude-test",
                modelContext: modelContext
            )
            Issue.record("Expected sendMessage to fail after the fake service captured the request")
        } catch {
            // Expected: the fake service aborts after capturing the outgoing parameter.
        }

        let captured = try #require(fakeService.capturedMessageParameter)
        let userTexts = captured.messages
            .filter { $0.role == "user" }
            .map { claudeService.extractText(from: $0.content) }

        let previousMessageOccurrences = userTexts.filter { $0 == "上一条消息" }.count
        let currentMessageOccurrences = userTexts.filter { $0 == "放松一下" }.count

        if currentMessageOccurrences != 1 || previousMessageOccurrences != 1 {
            Issue.record("Captured user texts: \(userTexts)")
        }

        #expect(previousMessageOccurrences == 1)
        #expect(currentMessageOccurrences == 1)
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            SessionTaskState.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }
}

private final class CapturingAnthropicService: AnthropicService {
    let httpClient: HTTPClient = URLSessionHTTPClientAdapter()
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private(set) var capturedMessageParameter: MessageParameter?

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> {
        capturedMessageParameter = parameter
        throw CapturingAnthropicServiceError.stopAfterCapture
    }

    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens {
        throw CapturingAnthropicServiceError.unused
    }

    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> {
        throw CapturingAnthropicServiceError.unused
    }

    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func retrieveSkill(skillId: String) async throws -> SkillResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func deleteSkill(skillId: String) async throws {
        throw CapturingAnthropicServiceError.unused
    }

    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse {
        throw CapturingAnthropicServiceError.unused
    }

    func deleteSkillVersion(skillId: String, version: String) async throws {
        throw CapturingAnthropicServiceError.unused
    }
}

private enum CapturingAnthropicServiceError: Error {
    case unused
    case stopAfterCapture
}