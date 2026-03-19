import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RemoteConversationRouterTests {
    @Test func routerCreatesSessionForFirstRemoteConversation() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let message = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: "msg-1",
            externalUserID: "ou_user_1",
            text: "你好",
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: .now
        )

        let session = try harness.router.resolveSession(for: message, modelContext: harness.context)
        let bindings = try harness.context.fetch(FetchDescriptor<RemoteConversationBinding>())

        #expect(session.title.contains("Feishu"))
        #expect(bindings.count == 1)
        #expect(bindings.first?.sessionID == session.sessionId)
        #expect(bindings.first?.session?.sessionId == session.sessionId)
    }

    @Test func routerReusesExistingSessionForKnownRemoteConversation() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let session = Session.fixture(sessionId: "session-existing", title: "Existing")
        let binding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalUserID: "ou_user_1",
            session: session
        )
        harness.context.insert(session)
        harness.context.insert(binding)
        try harness.context.save()
        let message = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: "msg-1",
            externalUserID: "ou_user_1",
            text: "你好",
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: .now
        )

        let resolved = try harness.router.resolveSession(for: message, modelContext: harness.context)

        #expect(resolved.sessionId == session.sessionId)
    }

    @Test func routerPrunesStaleBindingAndRecreatesSession() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let staleBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalUserID: "ou_user_1",
            sessionID: "missing-session"
        )
        harness.context.insert(staleBinding)
        try harness.context.save()

        let resolved = try harness.router.resolveSession(for: .fixture(), modelContext: harness.context)
        let bindings = try harness.context.fetch(FetchDescriptor<RemoteConversationBinding>())

        #expect(bindings.count == 1)
        #expect(bindings.first?.sessionID == resolved.sessionId)
        #expect(bindings.first?.session?.sessionId == resolved.sessionId)
    }

    @Test func routerPrunesDuplicateBindingsForSameRemoteConversation() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let first = Session.fixture(sessionId: "session-1", title: "First")
        let second = Session.fixture(sessionId: "session-2", title: "Second")
        let olderBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalUserID: "ou_user_1",
            session: first,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let newerBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalUserID: "ou_user_1",
            session: second,
            createdAt: .now,
            updatedAt: .now
        )
        harness.context.insert(first)
        harness.context.insert(second)
        harness.context.insert(olderBinding)
        harness.context.insert(newerBinding)
        try harness.context.save()

        let resolved = try harness.router.resolveSession(for: .fixture(), modelContext: harness.context)
        let bindings = try harness.context.fetch(FetchDescriptor<RemoteConversationBinding>())

        #expect(resolved.sessionId == second.sessionId)
        #expect(bindings.count == 1)
        #expect(bindings.first?.session?.sessionId == second.sessionId)
    }

    @Test func routerIsolatedByChannelKind() throws {
        let harness = try RemoteConversationRouterHarness.make()
        let feishu = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: "msg-1",
            externalUserID: "ou_user_1",
            text: "你好",
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: .now
        )
        let firstSession = try harness.router.resolveSession(for: feishu, modelContext: harness.context)
        let mirrorBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "other-chat",
            externalUserID: "ou_other",
            session: firstSession
        )
        harness.context.insert(mirrorBinding)
        try harness.context.save()

        let alternative = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-2",
            externalMessageID: "msg-2",
            externalUserID: "ou_user_2",
            text: "hello",
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: .now
        )

        let secondSession = try harness.router.resolveSession(for: alternative, modelContext: harness.context)

        #expect(firstSession.sessionId != secondSession.sessionId)
    }
}

@MainActor
private struct RemoteConversationRouterHarness {
    let container: ModelContainer
    let context: ModelContext
    let router: RemoteConversationRouter

    static func make() throws -> RemoteConversationRouterHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Session.self,
            RemoteConversationBinding.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        return RemoteConversationRouterHarness(
            container: container,
            context: context,
            router: RemoteConversationRouter()
        )
    }
}

private extension InboundChannelMessage {
    static func fixture() -> InboundChannelMessage {
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
    }
}