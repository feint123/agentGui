import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopBusinessObservabilityTests {

    @Test func businessObservabilityHookMapsRunStartToLoopStartedEvent() async throws {
        let sink = InMemoryBusinessLogSink()
        let hook = BusinessObservabilityHook(sink: sink)

        let result = try await hook.perform(
            stage: .didStartRun,
            context: .testObservabilityContext(metadata: [
                "modelId": "claude-test",
                "maxRounds": 2,
                "messageCount": 1
            ])
        )

        #expect(result == .continue)
        #expect(sink.events.map(\.event) == [.loopStarted])
        #expect(sink.events.first?.metadata["modelId"] as? String == "claude-test")
    }

    @Test func businessObservabilityHookMapsBootstrapToMemoryBootstrapLoadedEvent() async throws {
        let sink = InMemoryBusinessLogSink()
        let hook = BusinessObservabilityHook(sink: sink)

        let result = try await hook.perform(
            stage: .didApplyBootstrap,
            context: .testObservabilityContext(metadata: ["profileCount": 2])
        )

        #expect(result == .continue)
        #expect(sink.events.map(\.event) == [.memoryBootstrapLoaded])
        #expect(sink.events.first?.metadata["profileCount"] as? Int == 2)
    }

    @Test func runCoreAgentLoopEmitsLifecycleEventsInOrder() async throws {
        let sink = InMemoryBusinessLogSink()
        let claudeService = ClaudeService()
        claudeService.businessLogSink = sink

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("fix the build"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: FakeAnthropicService.endTurn(text: "done"),
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: AppSettings(),
            sessionId: "",
            modelContext: try makeModelContext(),
            maxRounds: 2,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        #expect(result.completedSuccessfully)
        #expect(sink.events.map(\.event) == [
            .loopStarted,
            .roundStarted,
            .stopReasonReceived,
            .verificationGateEvaluated,
            .verificationSkipped,
            .loopFinished
        ])
    }

    @Test func runCoreAgentLoopFailsWhenToolUseStopReasonHasNoParsedTools() async throws {
        let claudeService = ClaudeService()

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("run a tool"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: FakeAnthropicService.toolUseWithoutBlocks(),
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: AppSettings(),
            sessionId: "",
            modelContext: try makeModelContext(),
            maxRounds: 2,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        #expect(!result.completedSuccessfully)
        #expect(result.terminationReason == "stop_reason=tool_use but no tool blocks parsed")
    }

    @Test func runCoreAgentLoopMaxRoundsFailureEmitsLoopFailedButNotLoopFinished() async throws {
        let sink = InMemoryBusinessLogSink()
        let claudeService = ClaudeService()
        claudeService.businessLogSink = sink

        var messages: [MessageParameter.Message] = [
            .init(role: .user, content: .text("do not start"))
        ]

        let result = try await claudeService.runCoreAgentLoop(
            messages: &messages,
            service: FakeAnthropicService.endTurn(text: "unused"),
            modelId: "claude-test",
            tools: [],
            system: nil,
            settings: AppSettings(),
            sessionId: "",
            modelContext: try makeModelContext(),
            maxRounds: 0,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none
        )

        #expect(!result.completedSuccessfully)
        #expect(result.terminationReason == "maxRounds")
        #expect(sink.events.map(\.event).contains(.loopFailed))
        #expect(!sink.events.map(\.event).contains(.loopFinished))
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

private final class FakeAnthropicService: AnthropicService {
    let httpClient: HTTPClient
    let decoder: JSONDecoder
    private let streamEvents: [MessageStreamResponse]

    private init(streamEvents: [MessageStreamResponse]) {
        self.httpClient = URLSessionHTTPClientAdapter()
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.streamEvents = streamEvents
    }

    static func endTurn(text: String) -> FakeAnthropicService {
        FakeAnthropicService(streamEvents: [
            decodeStreamEvent("""
            {"type":"content_block_delta","delta":{"type":"text_delta","text":"\(text)"}}
            """),
            decodeStreamEvent("""
            {"type":"message_delta","delta":{"stop_reason":"end_turn"}}
            """)
        ])
    }

    static func toolUseWithoutBlocks() -> FakeAnthropicService {
        FakeAnthropicService(streamEvents: [
            decodeStreamEvent("""
            {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
            """)
        ])
    }

    func createMessage(_ parameter: MessageParameter) async throws -> MessageResponse {
        throw FakeError.unused
    }

    func streamMessage(_ parameter: MessageParameter) async throws -> AsyncThrowingStream<MessageStreamResponse, Error> {
        let events = streamEvents
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func countTokens(parameter: MessageTokenCountParameter) async throws -> MessageInputTokens {
        throw FakeError.unused
    }

    func createTextCompletion(_ parameter: TextCompletionParameter) async throws -> TextCompletionResponse {
        throw FakeError.unused
    }

    func createStreamTextCompletion(_ parameter: TextCompletionParameter) async throws -> AsyncThrowingStream<TextCompletionStreamResponse, Error> {
        throw FakeError.unused
    }

    func createSkill(_ parameter: SkillCreateParameter) async throws -> SkillResponse {
        throw FakeError.unused
    }

    func listSkills(parameter: ListSkillsParameter?) async throws -> ListSkillsResponse {
        throw FakeError.unused
    }

    func retrieveSkill(skillId: String) async throws -> SkillResponse {
        throw FakeError.unused
    }

    func deleteSkill(skillId: String) async throws {
        throw FakeError.unused
    }

    func createSkillVersion(skillId: String, _ parameter: SkillVersionCreateParameter) async throws -> SkillVersionResponse {
        throw FakeError.unused
    }

    func listSkillVersions(skillId: String, parameter: ListSkillVersionsParameter?) async throws -> ListSkillVersionsResponse {
        throw FakeError.unused
    }

    func retrieveSkillVersion(skillId: String, version: String) async throws -> SkillVersionResponse {
        throw FakeError.unused
    }

    func deleteSkillVersion(skillId: String, version: String) async throws {
        throw FakeError.unused
    }
}

private enum FakeError: Error {
    case unused
}

private func decodeStreamEvent(_ json: String) -> MessageStreamResponse {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = Data(json.utf8)
    return try! decoder.decode(MessageStreamResponse.self, from: data)
}

private extension AgentLoopHookContext {
    static func testObservabilityContext(metadata: [String: Any] = [:]) -> AgentLoopHookContext {
        var context = AgentLoopHookContext(
            runID: "run-1",
            sessionID: "session-1",
            workflowID: nil,
            executionContext: .mainAgent,
            modelId: "claude-test",
            roundIndex: 0,
            phase: "executing"
        )
        context.metadata = metadata
        return context
    }
}