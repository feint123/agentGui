import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ChannelRuntimeBootstrapTests {
    @Test func bootstrapStartsEnabledFeishuChannel() async throws {
        let harness = try ChannelRuntimeBootstrapHarness.make(feishuEnabled: true, executionResult: .success("已处理"))

        try await harness.bootstrap.startEnabledChannels(modelContext: harness.context)

        #expect(harness.adapter.startCallCount == 1)
    }

    @Test func bootstrapProcessesInboundMessageEndToEnd() async throws {
        let harness = try ChannelRuntimeBootstrapHarness.make(feishuEnabled: true, executionResult: .success("已处理"))
        try await harness.bootstrap.startEnabledChannels(modelContext: harness.context)

        try await harness.adapter.emitInbound(
            InboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "p2p-chat-1",
                externalMessageID: "msg-1",
                externalUserID: "ou_user_1",
                text: "你好",
                mentionsBot: false,
                rawPayload: "{}",
                receivedAt: .now
            )
        )

        let messages = try harness.context.fetch(FetchDescriptor<Message>())
        let containsUserMessage = messages.contains { message in
            message.direction == .user && message.textContent == "你好"
        }
        let containsAgentMessage = messages.contains { message in
            message.direction == .agent && message.textContent == "已处理"
        }

        #expect(containsUserMessage)
        #expect(containsAgentMessage)
        #expect(harness.adapter.sentMessages.count == 1)
    }

    @Test func bootstrapPreservesInboundMessageFieldsInsideConfigurationHandler() async throws {
        let harness = try ChannelRuntimeBootstrapHarness.make(feishuEnabled: true, executionResult: .success("已处理"))
        try await harness.bootstrap.startEnabledChannels(modelContext: harness.context)

        let inbound = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-42",
            externalMessageID: "msg-42",
            externalUserID: "ou_user_42",
            text: "保留全部字段",
            mentionsBot: true,
            rawPayload: #"{"text":"保留全部字段"}"#,
            receivedAt: Date(timeIntervalSince1970: 1_234_567)
        )

        try await harness.adapter.emitInbound(inbound)

        #expect(harness.probe.receivedMessages == [inbound])
    }

    @Test func bootstrapStopsDisabledChannel() async throws {
        let harness = try ChannelRuntimeBootstrapHarness.make(feishuEnabled: false, executionResult: .success("已处理"))
        harness.registry.register(harness.adapter)

        await harness.bootstrap.stopDisabledChannels(modelContext: harness.context)

        #expect(harness.adapter.stopCallCount == 1)
    }
}

@MainActor
private struct ChannelRuntimeBootstrapHarness {
    let container: ModelContainer
    let context: ModelContext
    let adapter: BootstrapTestAdapter
    let registry: IMChannelRegistry
    let probe: BootstrapExecutionProbe
    let bootstrap: ChannelRuntimeBootstrap

    static func make(feishuEnabled: Bool, executionResult: BootstrapStubExecutor.Result) throws -> ChannelRuntimeBootstrapHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: AppSettings.self,
            Session.self,
            Message.self,
            ChannelAccountBinding.self,
            RemoteConversationBinding.self,
            RemoteMessageReceipt.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.insert(AppSettings.testFixture(apiKey: "sk-ant-test"))
        let binding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            displayName: "飞书",
            isEnabled: feishuEnabled
        )
        context.insert(binding)
        try context.save()

        let adapter = BootstrapTestAdapter(kind: .feishu)
        let registry = IMChannelRegistry()
        let probe = BootstrapExecutionProbe()
        registry.register(adapter)
        let delivery = OutboundDeliveryCoordinator { kind in
            guard kind == .feishu else {
                return nil
            }
            return adapter
        }
        let bootstrap = ChannelRuntimeBootstrap(
            registry: registry,
            orchestrator: RemoteAgentOrchestrator(
                router: RemoteConversationRouter(),
                executor: BootstrapStubExecutor(result: executionResult, probe: probe),
                deliveryCoordinator: delivery
            ),
            deduplicator: ChannelEventDeduplicator()
        )

        return ChannelRuntimeBootstrapHarness(
            container: container,
            context: context,
            adapter: adapter,
            registry: registry,
            probe: probe,
            bootstrap: bootstrap
        )
    }
}

@MainActor
private final class BootstrapExecutionProbe {
    private(set) var receivedMessages: [InboundChannelMessage] = []

    func record(_ message: InboundChannelMessage) {
        receivedMessages.append(message)
    }
}

@MainActor
private struct BootstrapStubExecutor: RemoteAgentExecuting {
    enum Result {
        case success(String)
    }

    let result: Result
    let probe: BootstrapExecutionProbe

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        modelContext: ModelContext
    ) async throws -> String {
        probe.record(message)
        _ = session
        _ = policy
        _ = authorizationPolicy
        _ = modelContext
        switch result {
        case .success(let text):
            return text
        }
    }
}

@MainActor
private final class BootstrapTestAdapter: IMChannelAdapter {
    let kind: IMChannelKind
    private(set) var configuration: IMChannelConfiguration?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var sentMessages: [OutboundChannelMessage] = []

    init(kind: IMChannelKind) {
        self.kind = kind
    }

    func start(configuration: IMChannelConfiguration) async throws {
        self.configuration = configuration
        startCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
        configuration = nil
    }

    func send(_ message: OutboundChannelMessage) async throws -> String {
        sentMessages.append(message)
        return UUID().uuidString
    }

    func emitInbound(_ message: InboundChannelMessage) async throws {
        try await configuration?.inboundMessageHandler(message)
    }
}