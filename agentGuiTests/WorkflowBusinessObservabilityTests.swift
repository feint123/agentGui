import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct WorkflowBusinessObservabilityTests {

    @Test func workflowRunnerEmitsActivationLifecycleEvents() async throws {
        let sink = InMemoryBusinessLogSink()
        let claudeService = ClaudeService()
        claudeService.businessLogSink = sink

        let runner = WorkflowAgentRunner(
            claudeService: claudeService,
            service: WorkflowFakeAnthropicService.endTurn(text: "review complete"),
            modelId: "claude-test",
            settings: AppSettings(),
            modelContext: try makeModelContext()
        )

        let role = try #require(WorkflowRoleDefinition.find(named: "verifier"))
        let context = WorkflowContext(sessionId: "", definitionId: "test-workflow", userTask: "review the implementation")
        let activationRecord = WorkflowActivationRecord(
            workflowId: context.workflowId,
            role: role.name,
            roleDisplayName: role.displayName,
            triggerReason: "scheduled"
        )

        let result = try await runner.run(
            role: role,
            context: context,
            inboxMessages: [],
            activationRecord: activationRecord
        )

        #expect(result.resultKind == .success)
        let workflowEvents = sink.events.filter {
            $0.event == .workflowActivationStarted || $0.event == .workflowActivationFinished
        }
        #expect(workflowEvents.map(\.event) == [.workflowActivationStarted, .workflowActivationFinished])
        #expect(workflowEvents.allSatisfy { ($0.metadata["workflowID"] as? String) == context.workflowId.uuidString })
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }
}

private final class WorkflowFakeAnthropicService: AnthropicService {
    let httpClient: HTTPClient
    let decoder: JSONDecoder
    private let streamEvents: [MessageStreamResponse]

    private init(streamEvents: [MessageStreamResponse]) {
        self.httpClient = URLSessionHTTPClientAdapter()
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.streamEvents = streamEvents
    }

    static func endTurn(text: String) -> WorkflowFakeAnthropicService {
        WorkflowFakeAnthropicService(streamEvents: [
            decodeWorkflowStreamEvent("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"\(text)"}}
            """),
            decodeWorkflowStreamEvent("""
            {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
            """)
        ])
    }

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse { throw WorkflowFakeError.unused }
    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> {
        let events = streamEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens { throw WorkflowFakeError.unused }
    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse { throw WorkflowFakeError.unused }
    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> { throw WorkflowFakeError.unused }
    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse { throw WorkflowFakeError.unused }
    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse { throw WorkflowFakeError.unused }
    func retrieveSkill(skillId: String) async throws -> SkillResponse { throw WorkflowFakeError.unused }
    func deleteSkill(skillId: String) async throws { throw WorkflowFakeError.unused }
    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse { throw WorkflowFakeError.unused }
    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse { throw WorkflowFakeError.unused }
    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse { throw WorkflowFakeError.unused }
    func deleteSkillVersion(skillId: String, version: String) async throws { throw WorkflowFakeError.unused }
}

private enum WorkflowFakeError: Error {
    case unused
}

private func decodeWorkflowStreamEvent(_ json: String) -> MessageStreamResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(MessageStreamResponse.self, from: Data(json.utf8))
}