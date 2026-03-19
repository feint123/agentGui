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

        await harness.bootstrap.waitForIdle()

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

        await harness.bootstrap.waitForIdle()

        #expect(harness.probe.receivedMessages == [inbound])
    }

    @Test func bootstrapReturnsInboundHandlerBeforeExecutionCompletes() async throws {
        let gate = AsyncGate()
        let harness = try ChannelRuntimeBootstrapHarness.make(
            feishuEnabled: true,
            executionResult: .blocked(gate, "已处理")
        )
        try await harness.bootstrap.startEnabledChannels(modelContext: harness.context)

        let returned = LockedBox(false)
        let emitTask = Task {
            try await harness.adapter.emitInbound(
                InboundChannelMessage(
                    channelKind: .feishu,
                    externalConversationID: "p2p-chat-1",
                    externalMessageID: "msg-async-1",
                    externalUserID: "ou_user_1",
                    text: "异步执行",
                    mentionsBot: false,
                    rawPayload: "{}",
                    receivedAt: .now
                )
            )
            returned.set(true)
        }

        await gate.waitUntilStarted()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(returned.value == true)

        await gate.release()
        _ = try await emitTask.value
        await harness.bootstrap.waitForIdle()
    }

    @Test func bootstrapSerializesTurnsPerRemoteConversation() async throws {
        let firstGate = AsyncGate()
        let harness = try ChannelRuntimeBootstrapHarness.make(
            feishuEnabled: true,
            executionResult: .sequenced(firstGate, ["第一条", "第二条"])
        )
        try await harness.bootstrap.startEnabledChannels(modelContext: harness.context)

        try await harness.adapter.emitInbound(
            InboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "p2p-chat-serial",
                externalMessageID: "msg-1",
                externalUserID: "ou_user_1",
                text: "第一条",
                mentionsBot: false,
                rawPayload: "{}",
                receivedAt: .now
            )
        )
        try await harness.adapter.emitInbound(
            InboundChannelMessage(
                channelKind: .feishu,
                externalConversationID: "p2p-chat-serial",
                externalMessageID: "msg-2",
                externalUserID: "ou_user_1",
                text: "第二条",
                mentionsBot: false,
                rawPayload: "{}",
                receivedAt: .now
            )
        )

        await firstGate.waitUntilStarted()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(harness.probe.receivedMessages.map(\.externalMessageID) == ["msg-1"])

        await firstGate.release()
        await harness.bootstrap.waitForIdle()

        #expect(harness.probe.receivedMessages.map(\.externalMessageID) == ["msg-1", "msg-2"])
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
                remoteDeliveryCoordinator: RemoteTurnDeliveryCoordinator(driver: nil),
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
        case blocked(AsyncGate, String)
        case sequenced(AsyncGate, [String])
    }

    let result: Result
    let probe: BootstrapExecutionProbe
    private let responseCursor = LockedBox(0)

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        deliveryHandle: (any RemoteTurnDeliveryHandle)?,
        modelContext: ModelContext
    ) async throws -> String {
        probe.record(message)
        _ = session
        _ = policy
        _ = authorizationPolicy
        _ = deliveryHandle
        _ = modelContext
        switch result {
        case .success(let text):
            return text
        case .blocked(let gate, let text):
            await gate.markStarted()
            await gate.waitForRelease()
            return text
        case .sequenced(let gate, let responses):
            if message.externalMessageID == "msg-1" {
                await gate.markStarted()
                await gate.waitForRelease()
            }
            let index = responseCursor.modify { cursor in
                defer { cursor += 1 }
                return cursor
            }
            return responses[index]
        }
    }
}

private actor AsyncGate {
    private var started = false
    private var released = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let continuations = startContinuations
        startContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ storage: Value) {
        self.storage = storage
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Value) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }

    func modify<Result>(_ transform: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return transform(&storage)
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