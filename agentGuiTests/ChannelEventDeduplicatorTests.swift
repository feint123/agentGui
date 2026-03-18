import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ChannelEventDeduplicatorTests {
    @Test func identicalInboundMessageIsOnlyAcceptedOnce() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deduplicator = ChannelEventDeduplicator()
        let message = InboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: "msg-1",
            externalUserID: "ou_user_1",
            text: "你好",
            mentionsBot: false,
            rawPayload: "{}",
            receivedAt: Date(timeIntervalSince1970: 100)
        )

        let firstAccepted = try deduplicator.acceptInbound(message, modelContext: context)
        let secondAccepted = try deduplicator.acceptInbound(message, modelContext: context)
        let receipts = try context.fetch(FetchDescriptor<RemoteMessageReceipt>())

        #expect(firstAccepted == true)
        #expect(secondAccepted == false)
        #expect(receipts.count == 1)
        #expect(receipts.first?.externalMessageID == "msg-1")
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: RemoteMessageReceipt.self,
            configurations: configuration
        )
    }
}