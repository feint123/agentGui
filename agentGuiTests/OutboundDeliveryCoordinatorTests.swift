import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct OutboundDeliveryCoordinatorTests {
    @Test func deliveryCreatesOutboundReceiptAfterSuccessfulSend() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: RemoteMessageReceipt.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let adapter = DeliveryTestChannelAdapter(kind: .feishu, sentMessageID: "out-1")
        let coordinator = OutboundDeliveryCoordinator { kind in
            kind == .feishu ? adapter : nil
        }
        let outbound = OutboundChannelMessage(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            text: "已处理"
        )

        let externalMessageID = try await coordinator.deliver(outbound, sourceMessage: nil, modelContext: context)
        let receipts = try context.fetch(FetchDescriptor<RemoteMessageReceipt>())

        #expect(externalMessageID == "out-1")
        #expect(adapter.sentMessages == [outbound])
        #expect(receipts.count == 1)
        #expect(receipts.first?.direction == .outbound)
        #expect(receipts.first?.externalMessageID == "out-1")
    }
}

@MainActor
private final class DeliveryTestChannelAdapter: IMChannelAdapter {
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