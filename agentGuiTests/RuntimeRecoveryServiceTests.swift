import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RuntimeRecoveryServiceTests {

    @Test func findsPendingAgentMessagesAtStartup() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = Session(sessionId: "s2", title: "Recovery")
        let message = Message.agentMessage(text: "partial", session: session)
        message.status = .pending
        context.insert(session)
        context.insert(message)
        try context.save()

        let service = RuntimeRecoveryService()
        let summary = try service.loadRecoverySummary(from: context)

        #expect(summary.items.count == 1)
        #expect(summary.items.first?.sourceKind == .messageGeneration)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Session.self,
            Message.self,
            RecoverySnapshot.self,
            configurations: config
        )
    }
}