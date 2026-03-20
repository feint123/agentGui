import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct DataIntegrityCheckerTests {

    @Test func flagsBrokenPlanJsonInsteadOfCrashing() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "s1", title: "Broken Plan")
        session.planJson = "{not-json"
        context.insert(session)
        try context.save()

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .brokenPlanJSON })
    }

    @Test func flagsOrphanMessageWithoutSession() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let message = Message(direction: .agent, contentType: .text, text: "orphan", session: nil)
        context.insert(message)
        try context.save()

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .orphanMessage })
    }

    @Test func flagsToolCallWithoutOwningMessage() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let toolCall = ToolCall(toolCallId: "tool-1", kind: .read, message: nil)
        context.insert(toolCall)
        try context.save()

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .orphanToolCall })
    }

    @Test func flagsReceiptWithoutOwningMessage() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let receipt = RemoteMessageReceipt(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalMessageID: "om-1",
            direction: .outbound,
            messageID: UUID()
        )
        context.insert(receipt)
        try context.save()

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .orphanRemoteMessageReceipt })
    }

    @Test func flagsStaleAndDuplicateRemoteBindings() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "s1", title: "Bound")
        let validBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalUserID: "ou_1",
            session: session
        )
        let staleBinding = RemoteConversationBinding(
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalUserID: "ou_1",
            sessionID: "missing-session"
        )
        context.insert(session)
        context.insert(validBinding)
        context.insert(staleBinding)
        try context.save()

        let report = try DataIntegrityChecker().runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .staleRemoteConversationBinding })
        #expect(report.issues.contains { $0.kind == .duplicateRemoteConversationBinding })
    }

    @Test func flagsOrphanProjectionResources() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let binding = SessionProjectionBinding(
            sessionID: "missing-session",
            channelKind: .feishu,
            externalConversationID: "chat-1"
        )
        let delivery = ChannelProjectionDelivery(
            sessionID: "missing-session",
            channelKind: .feishu,
            externalConversationID: "chat-1",
            externalMessageID: "om-1",
            deliveryKind: .primary
        )
        context.insert(binding)
        context.insert(delivery)
        try context.save()

        let report = try DataIntegrityChecker().runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .orphanSessionProjectionBinding })
        #expect(report.issues.contains { $0.kind == .orphanChannelProjectionDelivery })
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Session.self,
            Message.self,
            RemoteMessageReceipt.self,
            RemoteConversationBinding.self,
            SessionProjectionBinding.self,
            ChannelProjectionDelivery.self,
            ToolCall.self,
            IntegrityIssue.self,
            configurations: config
        )
    }
}