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

    @Test func dependencyFactoryLoadsEpistemicStateDuringBootstrap() async throws {
        let service = ClaudeService()
        service.sessionEpistemicInputs["session-1"] = [
            EpistemicInputEnvelope(
                sessionID: "session-1",
                roundIndex: 1,
                userAgentMessages: ["Fix build"],
                toolObservations: ["Need to verify shared scheme"]
            )
        ]

        let modelContext = try makeModelContext()
        let request = makeRequest(service: ExtractionAnthropicService())
        let runtime = makeRuntime(modelContext: modelContext)
        let factory = AgentLoopHookDependencyFactory(
            claudeService: service,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let state = AgentLoopBuiltInHookFactory.State()

        try await factory.loadEpistemicBootstrapState(into: state)

        #expect(state.epistemicState.frontiers.count == 1)
        #expect(state.epistemicState.frontiers.first?.openClaim == "Need to verify shared scheme")
    }

    @Test func dependencyFactoryUsesRealCoordinatorWhenEpistemicExtractionEnabled() async throws {
        let service = ClaudeService()
        service.sessionEpistemicInputs["session-1"] = [
            EpistemicInputEnvelope(
                sessionID: "session-1",
                roundIndex: 1,
                userAgentMessages: ["Fix build"],
                toolObservations: ["Need to verify shared scheme"]
            )
        ]

        let settings = AppSettings()
        settings.enableEpistemicExtraction = true

        let modelContext = try makeModelContext()
        let request = makeRequest(service: StructuredExtractionAnthropicService())
        let runtime = makeRuntime(modelContext: modelContext, settings: settings)
        let factory = AgentLoopHookDependencyFactory(
            claudeService: service,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let state = AgentLoopBuiltInHookFactory.State()

        try await factory.loadEpistemicBootstrapState(into: state)

        #expect(state.epistemicState.frontiers.first?.openClaim == "Structured frontier from model")
        #expect(state.influenceTrace.rankedActionIDs == ["Run xcodebuild -list"])
    }

    @Test func dependencyFactorySkipsBootstrapExtractionForSubagentContext() async throws {
        let service = ClaudeService()
        service.sessionEpistemicInputs["session-1"] = [
            EpistemicInputEnvelope(
                sessionID: "session-1",
                roundIndex: 1,
                userAgentMessages: ["Investigate crash"],
                toolObservations: ["Subagent invocation triggered runtime crash"]
            )
        ]

        let settings = AppSettings()
        settings.enableEpistemicExtraction = true

        let extractionService = CountingExtractionAnthropicService()
        let modelContext = try makeModelContext()
        let request = makeRequest(service: extractionService, toolExecutionContext: .subagent)
        let runtime = makeRuntime(modelContext: modelContext, settings: settings)
        let factory = AgentLoopHookDependencyFactory(
            claudeService: service,
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let state = AgentLoopBuiltInHookFactory.State()

        try await factory.loadEpistemicBootstrapState(into: state)

        let invocationCount = await extractionService.createMessageInvocationCount
        #expect(invocationCount == 0)
        #expect(state.epistemicState.frontiers.isEmpty)
        #expect(state.influenceTrace.rankedActionIDs.isEmpty)
    }

    private func makeRequest(service: any AnthropicService) -> AgentLoopRunRequest {
        makeRequest(service: service, toolExecutionContext: .mainAgent)
    }

    private func makeRequest(
        service: any AnthropicService,
        toolExecutionContext: ToolContext
    ) -> AgentLoopRunRequest {
        AgentLoopRunRequest(
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            maxRounds: 2,
            toolExecutionContext: toolExecutionContext
        )
    }

    private func makeRuntime(
        modelContext: ModelContext,
        settings: AppSettings = AppSettings()
    ) -> AgentLoopRuntime {
        AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: "session-1",
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )
    }

    private func makeHookContext(phase: String) -> AgentLoopHookContext {
        AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: phase
        )
    }

    private func makeModelContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Message.self,
            ToolCall.self,
            AgentRound.self,
            configurations: config
        )
        return ModelContext(container)
    }
}

private final class TestAnthropicService: AnthropicService {
    let httpClient: HTTPClient = URLSessionHTTPClientAdapter()
    let decoder: JSONDecoder = JSONDecoder()

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse { throw TestError.unused }
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

private enum TestError: Error {
    case unused
}

private final class ExtractionAnthropicService: AnthropicService {
        let httpClient: HTTPClient = URLSessionHTTPClientAdapter()
        let decoder: JSONDecoder = JSONDecoder()

        func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
                _ = parameter
                return try JSONDecoder().decode(
                        MessageResponse.self,
                        from: Data(#"""
                        {
                            "id": "msg_1",
                            "type": "message",
                            "role": "assistant",
                            "model": "claude-test",
                            "content": [
                                {
                                    "type": "text",
                                    "text": "{\"objects\":[{\"kind\":\"frontier\",\"id\":\"f-1\",\"summary\":\"Need to verify shared scheme\",\"source_refs\":[\"message:user:0\"],\"decision_delta\":\"Run xcodebuild -list\",\"evidence_level\":\"partial\"}],\"rejected\":[],\"missingEvidence\":[],\"decisionImpactNote\":\"inspect first\"}"
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

private final class StructuredExtractionAnthropicService: AnthropicService {
    let httpClient: HTTPClient = URLSessionHTTPClientAdapter()
    let decoder: JSONDecoder = JSONDecoder()

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
        _ = parameter
        return try JSONDecoder().decode(
            MessageResponse.self,
            from: Data(#"""
            {
                "id": "msg_2",
                "type": "message",
                "role": "assistant",
                "model": "claude-test",
                "content": [
                    {
                        "type": "text",
                        "text": "{\"objects\":[{\"kind\":\"frontier\",\"id\":\"f-structured\",\"summary\":\"Structured frontier from model\",\"source_refs\":[\"message:user:0\"],\"decision_delta\":\"Run xcodebuild -list\",\"evidence_level\":\"partial\"}],\"rejected\":[],\"missingEvidence\":[],\"decisionImpactNote\":\"inspect first\"}"
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