import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RemoteAgentOrchestratorTests {
    @Test func orchestratorPersistsInboundAndOutboundMessages() async throws {
        let harness = try RemoteAgentHarness.make(executionResult: .success("仓库摘要"))

        try await harness.orchestrator.handleInbound(
            .fixture(text: "总结这个仓库"),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            executionPolicy: RemoteExecutionPolicy(),
            modelContext: harness.context
        )

        let messages = try harness.context.fetch(FetchDescriptor<Message>())
        let containsUserMessage = messages.contains { message in
            message.direction == .user && message.textContent == "总结这个仓库"
        }
        let containsAgentMessage = messages.contains { message in
            message.direction == .agent && message.textContent == "仓库摘要"
        }

        #expect(containsUserMessage)
        #expect(containsAgentMessage)
        #expect(harness.adapter.sentMessages.map(\.text) == ["仓库摘要"])
        #expect(harness.executor.lastDeliveryHandle != nil)
        #expect(harness.projectionSession.events.isEmpty)
    }

    @Test func orchestratorSkipsFinalOutboundWhenProjectionAlreadyDelivered() async throws {
        let harness = try RemoteAgentHarness.make(
            executionResult: .projectedSuccess("仓库摘要"),
            projectionMode: .completeWithRemoteDelivery(messageID: "om_projection_1")
        )

        try await harness.orchestrator.handleInbound(
            .fixture(text: "总结这个仓库"),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            executionPolicy: RemoteExecutionPolicy(),
            modelContext: harness.context
        )

        let bindings = try harness.context.fetch(FetchDescriptor<SessionProjectionBinding>())

        #expect(harness.adapter.sentMessages.isEmpty)
        #expect(bindings.count == 1)
        #expect(bindings.first?.primaryExternalMessageID == "om_projection_1")
        #expect(bindings.first?.state == .completed)
    }

    @Test func orchestratorSendsFailureSummaryWhenExecutionFails() async throws {
        let harness = try RemoteAgentHarness.make(executionResult: .failure(TestExecutionError.failed))

        try await harness.orchestrator.handleInbound(
            .fixture(text: "总结这个仓库"),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            executionPolicy: RemoteExecutionPolicy(),
            modelContext: harness.context
        )

        let messages = try harness.context.fetch(FetchDescriptor<Message>())
        let containsFailureSystemMessage = messages.contains { message in
            message.direction == .system && (message.textContent?.contains("执行失败") ?? false)
        }

        #expect(containsFailureSystemMessage)
        #expect(harness.adapter.sentMessages.count == 1)
        #expect(harness.adapter.sentMessages[0].text.contains("执行失败"))
        #expect(harness.projectionSession.events.count == 1)
        if case .failed(let summary) = try #require(harness.projectionSession.events.first) {
            #expect(summary.contains("执行失败"))
        } else {
            Issue.record("expected a failed projection event")
        }
    }

    @Test func orchestratorSkipsFailureFallbackWhenProjectionAlreadyDelivered() async throws {
        let harness = try RemoteAgentHarness.make(
            executionResult: .failure(TestExecutionError.failed),
            projectionMode: .failWithRemoteDelivery(messageID: "om_projection_1")
        )

        try await harness.orchestrator.handleInbound(
            .fixture(text: "总结这个仓库"),
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            executionPolicy: RemoteExecutionPolicy(),
            modelContext: harness.context
        )

        let bindings = try harness.context.fetch(FetchDescriptor<SessionProjectionBinding>())

        #expect(harness.adapter.sentMessages.isEmpty)
        #expect(bindings.count == 1)
        #expect(bindings.first?.primaryExternalMessageID == "om_projection_1")
        #expect(bindings.first?.state == .failed)
    }

    @Test func orchestratorBuildsProjectionContextBeforeExecution() async throws {
        let harness = try RemoteAgentHarness.make(executionResult: .success("仓库摘要"))
        let inbound = InboundChannelMessage.fixture(text: "总结这个仓库")

        try await harness.orchestrator.handleInbound(
            inbound,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly),
            executionPolicy: RemoteExecutionPolicy(),
            modelContext: harness.context
        )

        let sessions = try harness.context.fetch(FetchDescriptor<Session>())
        let createdSessionID = try #require(sessions.first?.sessionId)

        #expect(harness.openedContexts == [
            ChannelProjectionContext(
                channelKind: .feishu,
                externalConversationID: inbound.externalConversationID,
                replyToExternalMessageID: inbound.externalMessageID,
                sessionID: createdSessionID
            )
        ])
    }
}

@MainActor
private struct RemoteAgentHarness {
    let container: ModelContainer
    let context: ModelContext
    let adapter: TestChannelAdapter
    let executor: StubRemoteAgentExecutor
    let projectionSession: TestProjectionSession
    let openedContexts: LockedBox<[ChannelProjectionContext]>
    let orchestrator: RemoteAgentOrchestrator

    static func make(
        executionResult: StubRemoteAgentExecutor.Result,
        projectionMode: TestProjectionSession.Mode = .observeOnly
    ) throws -> RemoteAgentHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            RemoteConversationBinding.self,
            SessionProjectionBinding.self,
            RemoteMessageReceipt.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.insert(AppSettings.testFixture(apiKey: "sk-ant-test"))
        try context.save()

        let adapter = TestChannelAdapter(kind: .feishu, sentMessageID: "out-1")
        let projectionSession = TestProjectionSession(mode: projectionMode)
        let openedContexts = LockedBox<[ChannelProjectionContext]>([])
        let delivery = OutboundDeliveryCoordinator { kind in
            kind == .feishu ? adapter : nil
        }
        let remoteDeliveryCoordinator = RemoteTurnDeliveryCoordinator { context in
            openedContexts.withLock { $0.append(context) }
            projectionSession.attach(context: context)
            return projectionSession
        }
        let executor = StubRemoteAgentExecutor(result: executionResult)
        let orchestrator = RemoteAgentOrchestrator(
            router: RemoteConversationRouter(),
            executor: executor,
            remoteDeliveryCoordinator: remoteDeliveryCoordinator,
            deliveryCoordinator: delivery
        )
        return RemoteAgentHarness(
            container: container,
            context: context,
            adapter: adapter,
            executor: executor,
            projectionSession: projectionSession,
            openedContexts: openedContexts,
            orchestrator: orchestrator
        )
    }
}

private enum TestExecutionError: Error {
    case failed
}

@MainActor
private final class StubRemoteAgentExecutor: RemoteAgentExecuting {
    enum Result {
        case success(String)
        case projectedSuccess(String)
        case failure(Error)
    }

    let result: Result
    private(set) var lastDeliveryHandle: (any RemoteTurnDeliveryHandle)?

    init(result: Result) {
        self.result = result
    }

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        deliveryHandle: (any RemoteTurnDeliveryHandle)?,
        modelContext: ModelContext
    ) async throws -> String {
        switch result {
        case .success(let text):
            _ = authorizationPolicy
            _ = message
            _ = session
            _ = policy
            _ = modelContext
            lastDeliveryHandle = deliveryHandle
            return text
        case .projectedSuccess(let text):
            _ = authorizationPolicy
            _ = message
            _ = session
            _ = policy
            _ = modelContext
            lastDeliveryHandle = deliveryHandle
            await deliveryHandle?.finish(finalText: text)
            return text
        case .failure(let error):
            _ = authorizationPolicy
            _ = message
            _ = session
            _ = policy
            _ = modelContext
            lastDeliveryHandle = deliveryHandle
            throw error
        }
    }
}

@MainActor
private final class TestProjectionSession: ChannelProjectionSession {
    enum Mode {
        case observeOnly
        case completeWithRemoteDelivery(messageID: String)
        case failWithRemoteDelivery(messageID: String)
    }

    private let mode: Mode
    private(set) var events: [AgentLoopProjectionEvent] = []
    private(set) var closeCount = 0
    private var currentContext: ChannelProjectionContext?

    init(mode: Mode) {
        self.mode = mode
    }

    func attach(context: ChannelProjectionContext) {
        currentContext = context
    }

    func ingest(_ event: AgentLoopProjectionEvent) async throws {
        events.append(event)
        try persistProjectionIfNeeded(for: event)
    }

    func close() async {
        closeCount += 1
    }

    private func persistProjectionIfNeeded(for event: AgentLoopProjectionEvent) throws {
        guard let context = currentContext,
              let modelContext = context.modelContext else { return }

        switch (mode, event) {
        case (.completeWithRemoteDelivery(let messageID), .completed):
            try upsertBinding(
                messageID: messageID,
                state: .completed,
                modelContext: modelContext,
                context: context
            )
        case (.failWithRemoteDelivery(let messageID), .failed(let summary)):
            try upsertBinding(
                messageID: messageID,
                state: .failed,
                lastErrorSummary: summary,
                modelContext: modelContext,
                context: context
            )
        default:
            break
        }
    }

    private func upsertBinding(
        messageID: String,
        state: SessionProjectionBindingState,
        lastErrorSummary: String? = nil,
        modelContext: ModelContext,
        context: ChannelProjectionContext
    ) throws {
        let session = (try modelContext.fetch(FetchDescriptor<Session>())).first {
            $0.sessionId == context.sessionID
        }
        let binding = SessionProjectionBinding(
            session: session,
            sessionID: context.sessionID,
            channelKind: context.channelKind,
            externalConversationID: context.externalConversationID,
            formatHint: context.formatHint,
            primaryExternalMessageID: messageID,
            latestExternalMessageID: messageID,
            state: state,
            lastErrorSummary: lastErrorSummary
        )
        modelContext.insert(binding)
        try modelContext.save()
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private extension LockedBox where Value == [ChannelProjectionContext] {
    static func == (lhs: LockedBox<[ChannelProjectionContext]>, rhs: [ChannelProjectionContext]) -> Bool {
        lhs.withLock { $0 } == rhs
    }
}

@MainActor
private final class TestChannelAdapter: IMChannelAdapter {
    let kind: IMChannelKind
    let sentMessageID: String
    private(set) var sentMessages: [OutboundChannelMessage] = []

    init(kind: IMChannelKind, sentMessageID: String) {
        self.kind = kind
        self.sentMessageID = sentMessageID
    }

    func start(configuration: IMChannelConfiguration) async throws {}

    func stop() async {}

    func send(_ message: OutboundChannelMessage) async throws -> String {
        sentMessages.append(message)
        return sentMessageID
    }
}

private extension InboundChannelMessage {
    static func fixture(text: String) -> InboundChannelMessage {
        InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: UUID().uuidString,
            externalUserID: "ou_user_1",
            text: text,
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: .now
        )
    }
}