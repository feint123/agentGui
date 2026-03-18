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
    }
}

@MainActor
private struct RemoteAgentHarness {
    let container: ModelContainer
    let context: ModelContext
    let adapter: TestChannelAdapter
    let orchestrator: RemoteAgentOrchestrator

    static func make(executionResult: StubRemoteAgentExecutor.Result) throws -> RemoteAgentHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            RemoteConversationBinding.self,
            RemoteMessageReceipt.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.insert(AppSettings.testFixture(apiKey: "sk-ant-test"))
        try context.save()

        let adapter = TestChannelAdapter(kind: .feishu, sentMessageID: "out-1")
        let delivery = OutboundDeliveryCoordinator { kind in
            kind == .feishu ? adapter : nil
        }
        let orchestrator = RemoteAgentOrchestrator(
            router: RemoteConversationRouter(),
            executor: StubRemoteAgentExecutor(result: executionResult),
            deliveryCoordinator: delivery
        )
        return RemoteAgentHarness(
            container: container,
            context: context,
            adapter: adapter,
            orchestrator: orchestrator
        )
    }
}

private enum TestExecutionError: Error {
    case failed
}

@MainActor
private struct StubRemoteAgentExecutor: RemoteAgentExecuting {
    enum Result {
        case success(String)
        case failure(Error)
    }

    let result: Result

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        modelContext: ModelContext
    ) async throws -> String {
        switch result {
        case .success(let text):
            _ = authorizationPolicy
            return text
        case .failure(let error):
            _ = authorizationPolicy
            throw error
        }
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