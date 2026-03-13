import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopIntegrationTests {

    @Test func runCoreAgentLoopReturnsMaxRoundsFailureWhenLoopNeverExecutes() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("never start"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: SequencedFakeAnthropicService(streamBatches: []),
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-max-rounds",
            modelContext: modelContext,
            maxRounds: 0,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        #expect(!result.completedSuccessfully)
        #expect(result.terminationReason == "maxRounds")
        #expect(result.text.contains("[Stopped: maximum rounds reached]"))
    }

    @Test func runCoreAgentLoopExecutesRunSubagentAndPersistsSubagentAudit() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-subagent","name":"run_subagent"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"agent_name\\\":\\\"explore\\\",\\\"task\\\":\\\"Explore the fix\\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"subagent plan ready"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"outer loop finished"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("delegate this"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-subagent",
            modelContext: modelContext,
            maxRounds: 4,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())

        #expect(result.completedSuccessfully)
        #expect(result.text.contains("outer loop finished"))
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.subagentAgentName == "explore")
        #expect(toolCalls.first?.subagentResultKind == "text")
        #expect(toolCalls.first?.subagentMessageMetadata?["agent"] == "explore")
    }

    @Test func runCoreAgentLoopTracksForegroundBashTaskToCompletion() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-bash","name":"bash"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"command\\\":\\\"printf 'hello from bash\\\\n'; sleep 0.3\\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"bash round complete"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"passed\\":true,\\"summary\\":\\"bash verification passed\\",\\"verified_items\\":[\\"bash output observed\\"],\\"failed_items\\":[],\\"missing_evidence\\":[],\\"risk_areas\\":[],\\"recommended_next_action\\":\\"finish\\",\\"confidence\\":0.97}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        let settings = AppSettings.testFixture()
        settings.enableBashTool = true

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("run bash"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: settings,
            sessionId: "session-bash",
            modelContext: modelContext,
            maxRounds: 4,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        let record = try #require(toolCalls.first)
        let registry = claudeService.getBashTaskRegistry(for: "session-bash")
        let taskId = try #require(record.terminalTaskId)
        let snapshot = await registry.snapshot(taskId: taskId)
        let store = SessionTaskStateStore(modelContext: modelContext)
        let verification = try #require(store.verification(for: "session-bash"))

        #expect(result.completedSuccessfully)
        #expect(record.terminalTaskStatus == TerminalTaskStatus.completed.rawValue)
        #expect(record.terminalExecutionMode == TerminalExecutionMode.foreground.rawValue)
        #expect(record.terminalAgentActionsJSON != nil)
        #expect(snapshot?.status == .completed)
        #expect(snapshot?.latestOutputSnippet?.contains("hello from bash") == true)
        #expect(verification.passed == true)
        #expect(verification.summary == "bash verification passed")
    }

    @Test func runCoreAgentLoopInvokesVerifierSubagentBeforeReportingSuccess() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-verify","name":"verify_completion"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"verified\\\":[\\\"swift test passed\\\"],\\\"not_verified\\\":[],\\\"conclusion\\\":\\\"ready to finish\\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"passed\\":true,\\"summary\\":\\"verification passed\\",\\"verified_items\\":[\\"swift test passed\\"],\\"failed_items\\":[],\\"missing_evidence\\":[],\\"risk_areas\\":[],\\"recommended_next_action\\":\\"finish\\",\\"confidence\\":0.98}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("finish with verification"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-verifier",
            modelContext: modelContext,
            maxRounds: 5,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        let store = SessionTaskStateStore(modelContext: modelContext)
        let verification = try #require(store.verification(for: "session-verifier"))

        #expect(result.completedSuccessfully)
        #expect(toolCalls.contains(where: { $0.subagentAgentName == "verifier" }))
        #expect(verification.passed == true)
        #expect(verification.summary == "verification passed")
    }

    @Test func runCoreAgentLoopDoesNotUseLegacyExecutionRequirementGuard() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete without verify tool"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"passed\\":true,\\"summary\\":\\"verification passed without verify_completion\\",\\"verified_items\\":[\\"answer matches task\\"],\\"failed_items\\":[],\\"missing_evidence\\":[],\\"risk_areas\\":[],\\"recommended_next_action\\":\\"finish\\",\\"confidence\\":0.92}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("finish without verify_completion"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-verifier-no-tool",
            modelContext: modelContext,
            maxRounds: 5,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let store = SessionTaskStateStore(modelContext: modelContext)

        #expect(result.completedSuccessfully)
        #expect(result.terminationReason == nil)
        #expect(store.verification(for: "session-verifier-no-tool") == nil)
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

private final class SequencedFakeAnthropicService: AnthropicService {
    let httpClient: HTTPClient
    let decoder: JSONDecoder
    private let batches: StreamBatchStore

    init(streamBatches: [[MessageStreamResponse]]) {
        self.httpClient = URLSessionHTTPClientAdapter()
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.batches = StreamBatchStore(batches: streamBatches)
    }

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
        throw SequencedFakeError.unused
    }

    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> {
        let events = try await batches.nextBatch()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens {
        throw SequencedFakeError.unused
    }

    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse {
        throw SequencedFakeError.unused
    }

    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> {
        throw SequencedFakeError.unused
    }

    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse {
        throw SequencedFakeError.unused
    }

    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse {
        throw SequencedFakeError.unused
    }

    func retrieveSkill(skillId: String) async throws -> SkillResponse {
        throw SequencedFakeError.unused
    }

    func deleteSkill(skillId: String) async throws {
        throw SequencedFakeError.unused
    }

    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse {
        throw SequencedFakeError.unused
    }

    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse {
        throw SequencedFakeError.unused
    }

    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse {
        throw SequencedFakeError.unused
    }

    func deleteSkillVersion(skillId: String, version: String) async throws {
        throw SequencedFakeError.unused
    }
}

private actor StreamBatchStore {
    private var batches: [[MessageStreamResponse]]

    init(batches: [[MessageStreamResponse]]) {
        self.batches = batches
    }

    func nextBatch() throws -> [MessageStreamResponse] {
        guard !batches.isEmpty else {
            throw SequencedFakeError.noMoreBatches
        }
        return batches.removeFirst()
    }
}

private enum SequencedFakeError: Error {
    case unused
    case noMoreBatches
}

private func decodeStreamEvent(_ json: String) -> MessageStreamResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try! decoder.decode(MessageStreamResponse.self, from: Data(json.utf8))
}