import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct IMChannelModelTests {
    @Test func channelKindRoundTripsThroughCodable() throws {
        let encoded = try JSONEncoder().encode(IMChannelKind.feishu)
        let decoded = try JSONDecoder().decode(IMChannelKind.self, from: encoded)

        #expect(decoded == .feishu)
    }

    @Test func remoteExecutionPolicyDefaultsToRestrictedMode() {
        let policy = RemoteExecutionPolicy()

        #expect(policy.allowFileWrite == false)
        #expect(policy.allowBash == false)
        #expect(policy.allowNetworkTools == false)
        #expect(policy.maxRounds == 8)
    }

    @Test func channelAccountBindingDefaultsToDisabled() {
        let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")

        #expect(binding.channelKind == .feishu)
        #expect(binding.isEnabled == false)
        #expect(binding.configurationKey == "feishu.default")
    }

    @Test func remoteConversationBindingStoresStableConversationRoute() {
        let binding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalUserID: "ou_123",
            sessionID: "session-1"
        )

        #expect(binding.channelKind == .feishu)
        #expect(binding.externalConversationID == "p2p-chat-1")
        #expect(binding.sessionID == "session-1")
    }

    @Test func remoteMessageReceiptCapturesDirectionAndDedupKey() {
        let receipt = RemoteMessageReceipt(
            channelKind: .feishu,
            externalConversationID: "p2p-chat-1",
            externalMessageID: "om_123",
            direction: .inbound,
            messageID: nil
        )

        #expect(receipt.direction == .inbound)
        #expect(receipt.externalMessageID == "om_123")
        #expect(receipt.messageID == nil)
    }

    @Test func persistenceSchemaIncludesRemoteChannelModels() throws {
        let schemaTypeNames = Set(PersistenceSchema.sharedModelTypeNames)

        #expect(schemaTypeNames.contains("ChannelAccountBinding"))
        #expect(schemaTypeNames.contains("RemoteConversationBinding"))
        #expect(schemaTypeNames.contains("RemoteMessageReceipt"))

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(PersistenceSchema.sharedModelTypes),
            configurations: [configuration]
        )

        let _ = container.mainContext
    }
}