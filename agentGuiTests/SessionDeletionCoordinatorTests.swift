import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct SessionDeletionCoordinatorTests {
    @Test func deletionCoordinatorRejectsReadOnlySessions() throws {
        let harness = try SessionDeletionHarness.make()
        let session = Session.fixture(sessionId: "session-channel", title: "Channel", kind: .channel)
        harness.context.insert(session)
        try harness.context.save()

        #expect(throws: SessionDeletionCoordinatorError.self) {
            try harness.coordinator.delete(session, modelContext: harness.context)
        }

        #expect(try harness.context.fetch(FetchDescriptor<Session>()).count == 1)
    }

    @Test func deletionCoordinatorRemovesSessionAndChannelResources() throws {
        let harness = try SessionDeletionHarness.make()
        let session = Session.fixture(sessionId: "session-1", title: "Delete Me")
        let remoteBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalUserID: "ou_1",
            session: session
        )
        let projectionBinding = SessionProjectionBinding(
            session: session,
            channelKind: .feishu,
            externalConversationID: "chat-1"
        )
        let delivery = ChannelProjectionDelivery(
            session: session,
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalMessageID: "om-1",
            deliveryKind: .primary
        )
        let outboundMessage = Message.agentFixture(text: "reply", session: session)
        let receipt = RemoteMessageReceipt(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalMessageID: "om-receipt-1",
            direction: .outbound,
            messageID: outboundMessage.id
        )
        harness.context.insert(session)
        harness.context.insert(outboundMessage)
        harness.context.insert(remoteBinding)
        harness.context.insert(projectionBinding)
        harness.context.insert(delivery)
        harness.context.insert(receipt)
        try harness.context.save()

        try harness.coordinator.delete(session, modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<Session>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<RemoteConversationBinding>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<SessionProjectionBinding>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<ChannelProjectionDelivery>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<RemoteMessageReceipt>()).isEmpty)
    }

    @Test func deletionCoordinatorPrunesLegacySessionIdRows() throws {
        let harness = try SessionDeletionHarness.make()
        let session = Session.fixture(sessionId: "session-legacy", title: "Legacy")
        let staleBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "chat-legacy",
            externalUserID: "ou_legacy",
            sessionID: session.sessionId
        )
        harness.context.insert(session)
        harness.context.insert(staleBinding)
        try harness.context.save()

        try harness.coordinator.delete(session, modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<RemoteConversationBinding>()).isEmpty)
    }
}

@MainActor
private struct SessionDeletionHarness {
    let container: ModelContainer
    let context: ModelContext
    let coordinator: SessionDeletionCoordinator

    static func make() throws -> SessionDeletionHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Session.self,
            Message.self,
            RemoteConversationBinding.self,
            SessionProjectionBinding.self,
            ChannelProjectionDelivery.self,
            RemoteMessageReceipt.self,
            configurations: configuration
        )
        return SessionDeletionHarness(
            container: container,
            context: ModelContext(container),
            coordinator: SessionDeletionCoordinator()
        )
    }
}