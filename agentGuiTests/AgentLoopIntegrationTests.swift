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
        #expect(result.text.contains("[Stopped: maximum rounds reached]"))
    }

    @Test func runCoreAgentLoopPersistsTaskBoundRMSState() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("Fix the smoke failure"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: SequencedFakeAnthropicService(streamBatches: [[
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"I inspected the current failure output."}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]]),
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-rms-loop",
            modelContext: modelContext,
            maxRounds: 1,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let rmsState = SessionTaskStateStore(modelContext: modelContext).rmsState(for: "session-rms-loop")

        #expect(!result.text.isEmpty)
        #expect(rmsState?.summary == "Fix the smoke failure")
        #expect(rmsState?.sessionID == "session-rms-loop")
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
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-verify","name":"run_subagent"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"agent_name\\":\\"verifier\\",\\"task\\":\\"Check whether the delegated result is fully supported\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"passed\":true,\"summary\":\"delegated verification passed\",\"verified_items\":[\"subagent plan observed\"],\"failed_items\":[],\"missing_evidence\":[],\"risk_areas\":[],\"recommended_next_action\":\"finish\",\"confidence\":0.98}"}}
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
            maxRounds: 6,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())

        #expect(result.completedSuccessfully)
        #expect(result.text.contains("outer loop finished"))
        #expect(toolCalls.count == 2)
        #expect(toolCalls.first?.subagentAgentName == "explore")
        #expect(toolCalls.contains(where: { $0.subagentAgentName == "verifier" }))
        #expect(["text", "structured"].contains(toolCalls.first?.subagentResultKind ?? ""))
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
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-verify-bash","name":"run_subagent"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"agent_name\\":\\"verifier\\",\\"task\\":\\"Verify the observed bash output before finishing\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"passed\\":true,\\"summary\\":\\"bash verification passed\\",\\"verified_items\\":[\\"bash output observed\\"],\\"failed_items\\":[],\\"missing_evidence\\":[],\\"risk_areas\\":[],\\"recommended_next_action\\":\\"finish\\",\\"confidence\\":0.97}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"bash run finished"}}
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
            maxRounds: 6,
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

        let epistemicInputs = claudeService.sessionEpistemicInputs["session-bash"] ?? []
        #expect(!epistemicInputs.isEmpty)
        #expect(epistemicInputs.contains(where: { envelope in
            envelope.toolObservations.contains(where: { $0.contains("hello from bash") })
        }))
    }

    @Test func runCoreAgentLoopStartsForegroundBashWithExplicitTaskID() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-bash-explicit","name":"bash"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"operation\\\":\\\"start\\\",\\\"command\\\":\\\"printf 'explicit task id\\\\n'\\\",\\\"task_id\\\":\\\"view-dir-20250316\\\",\\\"execution_mode\\\":\\\"attached\\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"explicit bash round complete"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        let settings = AppSettings.testFixture()
        settings.enableBashTool = true

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("run bash with explicit task id"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: settings,
            sessionId: "session-bash-explicit",
            modelContext: modelContext,
            maxRounds: 4,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        let record = try #require(toolCalls.first)

        #expect(result.completedSuccessfully)
        #expect(record.status != .failed)
        #expect(record.terminalTaskId == "view-dir-20250316")
        #expect(record.terminalTaskStatus == TerminalTaskStatus.completed.rawValue)
        #expect((record.terminalOutput ?? record.toolResultSummary ?? "").contains("explicit task id"))
    }

    @Test func runCoreAgentLoopAutoRepliesToPackageInstallPrompt() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-bash-install","name":"bash"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\\"operation\\\":\\\"start\\\",\\\"command\\\":\\\"printf 'Need to install the following packages:\\\\ncreate-vue@3.22.0\\\\nOk to proceed? (y)'; read answer; printf '\\\\nanswer:%s\\\\n' \\\"$answer\\\"\\\",\\\"task_id\\\":\\\"npm-create-vue\\\",\\\"execution_mode\\\":\\\"attached\\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"package install prompt handled"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        let settings = AppSettings.testFixture()
        settings.enableBashTool = true

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("bootstrap vue project"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: settings,
            sessionId: "session-bash-auto-reply",
            modelContext: modelContext,
            maxRounds: 4,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())
        let record = try #require(toolCalls.first)

        #expect(result.completedSuccessfully)
        #expect(record.terminalTaskStatus == TerminalTaskStatus.completed.rawValue)
        #expect(record.terminalOutput?.contains("answer:y") == true)
        #expect(record.terminalAgentActionsJSON?.contains("已自动回复 y") == true)
    }

    @Test func runCoreAgentLoopFinishesAfterMainAgentExplicitlyInvokesVerifierSubagent() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-verify","name":"run_subagent"}}
                """),
                decodeStreamEvent("""
                {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"agent_name\\":\\"verifier\\",\\"task\\":\\"Check whether completion claims are fully supported\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\\"frontier_ranking\\":[],\\"missing_evidence\\":[],\\"residual_risks\\":[],\\"recommended_next_action\\":\\"finish\\"}"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete after verifier"}}
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
        #expect(verification.verificationState?.certificate?.decision == .pass)
        #expect(verification.verificationState?.certificate?.openClaims.isEmpty == true)
    }

    @Test func runCoreAgentLoopFinishesWithoutVerifierWhenAutoVerificationIsNotRequired() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"plain answer without tool-backed claims"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """),
            ]
        ])

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("Explain what this setting does"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-no-verifier-needed",
            modelContext: modelContext,
            maxRounds: 2,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let store = SessionTaskStateStore(modelContext: modelContext)

        #expect(result.completedSuccessfully)
        #expect(result.terminationReason == nil)
        #expect(store.verification(for: "session-no-verifier-needed") == nil)
    }

    @Test func runCoreAgentLoopDoesNotHostInvokeVerifierAfterEndTurn() async throws {
        let claudeService = ClaudeService()
        let modelContext = try makeModelContext()
        let service = SequencedFakeAnthropicService(streamBatches: [
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
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete again"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ]
        ])

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("finish with proof"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: service,
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: .testFixture(),
            sessionId: "session-no-host-verifier",
            modelContext: modelContext,
            maxRounds: 2,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        let toolCalls = try modelContext.fetch(FetchDescriptor<ToolCall>())

        #expect(!result.completedSuccessfully)
        #expect(!toolCalls.contains(where: { $0.subagentAgentName == "verifier" }))
    }

    @Test func runCoreAgentLoopDoesNotFinishWithoutVerifierOrEquivalentProof() async throws {
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
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete without verify tool again"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete without verify tool third round"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete without verify tool fourth round"}}
                """),
                decodeStreamEvent("""
                {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
                """)
            ],
            [
                decodeStreamEvent("""
                {"type":"content_block_delta","delta":{"type":"text_delta","text":"candidate complete without verify tool fifth round"}}
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

        #expect(!result.completedSuccessfully)
        #expect(result.terminationReason == "maxRounds")
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