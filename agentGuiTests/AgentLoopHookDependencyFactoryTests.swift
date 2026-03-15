import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopHookDependencyFactoryTests {

    @Test func dependencyFactoryCreatesToolRecordWithMemoryRuntimeMetadata() async throws {
        let service = ClaudeService()
        let modelContext = try makeModelContext()
        let request = makeRequest(service: TestAnthropicService())
        let runtime = makeRuntime(modelContext: modelContext)
        let factory = AgentLoopHookDependencyFactory(
            claudeService: service,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let state = AgentLoopBuiltInHookFactory.State()
        state.memoryRuntimeProfiles = ["coding"]
        state.memoryRuntimeLayers = ["task"]
        state.memoryRuntimeWarnings = ["warning"]
        state.memoryRuntimeSnapshotID = "snapshot-1"
        let dependencies = factory.build(state: state)
        var context = makeHookContext(phase: "awaitingToolResults")
        context.pendingToolName = "bash"
        context.toolInput = ["command": .string("ls")]
        context.metadata["toolUseID"] = "call-1"

        let record = try await dependencies.createToolCallRecord(context, state)

        #expect(record.toolCallId == "call-1")
        #expect(record.title == "ls")
        #expect(record.memoryRuntimeProfiles == ["coding"])
        #expect(record.memoryRuntimeLayers == ["task"])
        #expect(record.memoryRuntimeWarnings == ["warning"])
        #expect(record.memoryRuntimeSnapshotID == "snapshot-1")
    }

    @Test func dependencyFactoryUpdatesToolRecordFromHookContextMetadata() async throws {
        let service = ClaudeService()
        let modelContext = try makeModelContext()
        let request = makeRequest(service: TestAnthropicService())
        let runtime = makeRuntime(modelContext: modelContext)
        let factory = AgentLoopHookDependencyFactory(
            claudeService: service,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let state = AgentLoopBuiltInHookFactory.State()
        let dependencies = factory.build(state: state)
        let record = ToolCall(toolCallId: "call-2", kind: .execute)
        var context = makeHookContext(phase: "awaitingToolResults")
        context.toolCallRecord = record
        context.toolResultText = "full output"
        context.metadata = [
            "toolResultPreview": "preview",
            "toolResultSummary": "summary",
            "toolPayloadRef": "payload-1",
            "toolResultRawChars": 120,
            "toolResultInjectedChars": 30,
            "toolResultInjectionMode": "preview",
            "toolPayloadLastReadRange": "1-30",
            "toolPayloadReadCount": 2,
            "toolStatus": ToolStatus.success
        ]

        try await dependencies.updateToolCallRecord(context, state)

        #expect(record.terminalOutput == "preview")
        #expect(record.toolResultSummary == "summary")
        #expect(record.toolPayloadRef == "payload-1")
        #expect(record.toolResultRawChars == 120)
        #expect(record.toolResultInjectedChars == 30)
        #expect(record.toolResultInjectionMode == "preview")
        #expect(record.toolPayloadLastReadRange == "1-30")
        #expect(record.toolPayloadReadCount == 2)
        #expect(record.status == .success)
        #expect(record.endTime != nil)
    }

    private func makeRequest(service: any AnthropicService) -> AgentLoopRunRequest {
        makeRequest(service: service, toolExecutionContext: .mainAgent)
    }

    private func makeRequest(
        service: any AnthropicService,
            """#.utf8)
        )
    }

    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> { throw TestError.unused }
    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens { throw TestError.unused }
    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse { throw TestError.unused }
    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> { throw TestError.unused }
    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse { throw TestError.unused }
    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse { throw TestError.unused }
    func retrieveSkill(skillId: String) async throws -> SkillResponse { throw TestError.unused }
    func deleteSkill(skillId: String) async throws { throw TestError.unused }
    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse { throw TestError.unused }
    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse { throw TestError.unused }
    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse { throw TestError.unused }
    func deleteSkillVersion(skillId: String, version: String) async throws { throw TestError.unused }
}

private actor CreateMessageCounter {
    private(set) var count: Int = 0

    func increment() {
        count += 1
    }
}

private final class CountingExtractionAnthropicService: AnthropicService {
    let httpClient: HTTPClient = URLSessionHTTPClientAdapter()
    let decoder: JSONDecoder = JSONDecoder()
    private let counter = CreateMessageCounter()

    var createMessageInvocationCount: Int {
        get async {
            await counter.count
        }
    }

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
        _ = parameter
        await counter.increment()
        return try JSONDecoder().decode(
            MessageResponse.self,
            from: Data(#"""
            {
                "id": "msg_counting",
                "type": "message",
                "role": "assistant",
                "model": "claude-test",
                "content": [
                    {
                        "type": "text",
                        "text": "{\"objects\":[],\"rejected\":[],\"missingEvidence\":[],\"decisionImpactNote\":\"noop\"}"
                    }
                ],
                "stop_reason": "end_turn",
                "stop_sequence": null,
                "usage": { "input_tokens": 10, "output_tokens": 10 }
            }
            """#.utf8)
        )
    }

    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> { throw TestError.unused }
    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens { throw TestError.unused }
    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse { throw TestError.unused }
    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> { throw TestError.unused }
    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse { throw TestError.unused }
    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse { throw TestError.unused }
    func retrieveSkill(skillId: String) async throws -> SkillResponse { throw TestError.unused }
    func deleteSkill(skillId: String) async throws { throw TestError.unused }
    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse { throw TestError.unused }
    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse { throw TestError.unused }
    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse { throw TestError.unused }
    func deleteSkillVersion(skillId: String, version: String) async throws { throw TestError.unused }
}