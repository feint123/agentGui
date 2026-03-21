import Foundation
import SwiftAnthropic
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct AgentLoopHookEmitterTests {

    @Test func hookEmitterUsesProjectedTextAsDefaultCurrentRoundText() async throws {
        let capture = HookContextCapture()
        let dispatcher = AgentLoopHookDispatcher(hooks: [RecordingHook(capture: capture)])
        let emitter = AgentLoopHookEmitter(
            dispatcher: dispatcher,
            request: .testValue(),
            runtime: .testValue(),
            businessLogSink: nil
        )
        var state = AgentLoopRunState()
        state.accumulatedText = "older"

        _ = try await emitter.dispatch(
            .didReceiveTextDelta,
            state: state,
            messages: [],
            overrides: .init(projectedText: "newer")
        )

        let context = try #require(await capture.lastContext())
        #expect(context.currentRoundText == "newer")
        #expect(context.accumulatedText == "newer")
    }

    @Test func hookEmitterPrefersExplicitCurrentRoundTextOverProjectedText() async throws {
        let capture = HookContextCapture()
        let dispatcher = AgentLoopHookDispatcher(hooks: [RecordingHook(capture: capture)])
        let emitter = AgentLoopHookEmitter(
            dispatcher: dispatcher,
            request: .testValue(),
            runtime: .testValue(),
            businessLogSink: nil
        )
        var state = AgentLoopRunState()
        state.accumulatedText = "older"

        _ = try await emitter.dispatch(
            .didReceiveTextDelta,
            state: state,
            messages: [],
            overrides: .init(projectedText: "joined", currentRoundText: "delta")
        )

        let context = try #require(await capture.lastContext())
        #expect(context.currentRoundText == "delta")
        #expect(context.accumulatedText == "joined")
    }
}

private actor HookContextCapture {
    private var contexts: [AgentLoopHookContext] = []

    func append(_ context: AgentLoopHookContext) {
        contexts.append(context)
    }

    func lastContext() -> AgentLoopHookContext? {
        contexts.last
    }
}

private struct RecordingHook: AgentLoopHook {
    let id = "recording"
    let order = 0
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    let capture: HookContextCapture

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        true
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        await capture.append(context)
        return .continue
    }
}

private extension AgentLoopRunRequest {
    static func testValue() -> AgentLoopRunRequest {
        AgentLoopRunRequest(
            service: TestAnthropicService(),
            modelId: "claude-test",
            tools: [],
            system: nil,
            maxRounds: 2,
            toolExecutionContext: .mainAgent,
            toolApprovalMode: .bypassApprovals,
            runSource: "test",
            runLabel: nil,
            requestedBudgetSeconds: nil
        )
    }
}

private extension AgentLoopRuntime {
    static func testValue() -> AgentLoopRuntime {
        AgentLoopRuntime(
            settings: AppSettings(),
            session: nil,
            sessionId: "session-1",
            modelContext: try! makeModelContext(),
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )
    }
}

private func makeModelContext() throws -> ModelContext {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: AppSettings.self, AgentRound.self, configurations: config)
    return ModelContext(container)
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