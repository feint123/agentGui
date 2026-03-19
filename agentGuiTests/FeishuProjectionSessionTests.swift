import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct FeishuProjectionSessionTests {
    @Test func appendProjectionPersistsBindingAndDeliveries() async throws {
        let harness = try FeishuProjectionSessionHarness.make(format: .text)

        try await harness.session.ingest(.textSnapshot(accumulatedText: "第一段", currentRoundText: "第一段", roundIndex: 0, isForced: false))
        try await harness.session.ingest(.textSnapshot(accumulatedText: "第一段第二段", currentRoundText: "第二段", roundIndex: 0, isForced: false))
        try await harness.session.ingest(.completed(finalText: "第一段第二段"))

        let bindings = try harness.context.fetch(FetchDescriptor<SessionProjectionBinding>())
        let deliveries = try harness.context.fetch(FetchDescriptor<ChannelProjectionDelivery>())

        #expect(bindings.count == 1)
        #expect(bindings[0].sessionID == harness.sessionModel.sessionId)
        #expect(bindings[0].primaryExternalMessageID == "om_sent_1")
        #expect(bindings[0].latestExternalMessageID == "om_sent_2")
        #expect(bindings[0].state == .completed)
        #expect(deliveries.map(\.deliveryKind) == [.primary, .append, .finalize])
    }

    @Test func interactiveProjectionPersistsUpdatesAndFailureState() async throws {
        let harness = try FeishuProjectionSessionHarness.make(format: .interactive)

        try await harness.session.ingest(.textSnapshot(accumulatedText: "第一版", currentRoundText: "第一版", roundIndex: 0, isForced: false))
        try await harness.session.ingest(.textSnapshot(accumulatedText: "第一版\n第二版", currentRoundText: "第二版", roundIndex: 0, isForced: false))
        try await harness.session.ingest(.failed(summary: "执行失败：网络异常"))

        let bindings = try harness.context.fetch(FetchDescriptor<SessionProjectionBinding>())
        let deliveries = try harness.context.fetch(FetchDescriptor<ChannelProjectionDelivery>())

        #expect(bindings.count == 1)
        #expect(bindings[0].primaryExternalMessageID == "om_sent_1")
        #expect(bindings[0].latestExternalMessageID == "om_sent_1")
        #expect(bindings[0].state == .failed)
        #expect(bindings[0].lastErrorSummary == "执行失败：网络异常")
        #expect(deliveries.map(\.deliveryKind) == [.primary, .update, .update, .fail])
        #expect(harness.client.patchedPayloads.count == 2)
    }
}

@MainActor
private struct FeishuProjectionSessionHarness {
    let container: ModelContainer
    let context: ModelContext
    let sessionModel: Session
    let client: ProjectionTestFeishuClient
    let session: FeishuProjectionSession

    static func make(format: FeishuMessageFormat) throws -> FeishuProjectionSessionHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Session.self,
            SessionProjectionBinding.self,
            ChannelProjectionDelivery.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let sessionModel = Session.fixture(sessionId: "session-1", title: "Projection Session")
        context.insert(sessionModel)
        try context.save()

        let client = ProjectionTestFeishuClient()
        let session = FeishuProjectionSession(
            client: client,
            renderer: FeishuOutboundMessageRenderer(),
            format: format,
            chatID: "oc_test_chat",
            replyToMessageID: "om_source",
            title: "Feishu Bot",
            sessionID: sessionModel.sessionId,
            modelContext: context
        )
        return FeishuProjectionSessionHarness(
            container: container,
            context: context,
            sessionModel: sessionModel,
            client: client,
            session: session
        )
    }
}

@MainActor
private final class ProjectionTestFeishuClient: FeishuClient {
    struct SentPayload: Equatable {
        let chatID: String
        let payload: FeishuRenderedMessagePayload
        let replyToMessageID: String?
    }

    struct UpdatedPayload: Equatable {
        let messageID: String
        let payload: FeishuRenderedMessagePayload
    }

    private var nextMessageIndex = 1
    private(set) var sentPayloads: [SentPayload] = []
    private(set) var updatedPayloads: [UpdatedPayload] = []
    private(set) var patchedPayloads: [UpdatedPayload] = []

    func start(
        credentials: FeishuCredentials,
        onEvent: @escaping @MainActor @Sendable (FeishuEventEnvelope) async throws -> Void
    ) async throws {
        _ = credentials
        _ = onEvent
    }

    func stop() async {}

    func sendMessage(
        chatID: String,
        payload: FeishuRenderedMessagePayload,
        replyToMessageID: String?
    ) async throws -> String {
        sentPayloads.append(SentPayload(chatID: chatID, payload: payload, replyToMessageID: replyToMessageID))
        defer { nextMessageIndex += 1 }
        return "om_sent_\(nextMessageIndex)"
    }

    func updateMessage(messageID: String, payload: FeishuRenderedMessagePayload) async throws {
        updatedPayloads.append(UpdatedPayload(messageID: messageID, payload: payload))
    }

    func patchMessage(messageID: String, payload: FeishuRenderedMessagePayload) async throws {
        patchedPayloads.append(UpdatedPayload(messageID: messageID, payload: payload))
    }

    func sendText(chatID: String, text: String, replyToMessageID: String?) async throws -> String {
        try await sendMessage(
            chatID: chatID,
            payload: FeishuRenderedMessagePayload(msgType: "text", content: #"{"text":"\#(text)"}"#),
            replyToMessageID: replyToMessageID
        )
    }
}