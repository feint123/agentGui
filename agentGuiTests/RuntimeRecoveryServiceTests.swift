import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct RuntimeRecoveryServiceTests {

    @Test func findsInterruptedWorkflowInstancesAtStartup() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let workflow = WorkflowInstance(sessionId: "s1", definitionId: "code_change", userTask: "Ship feature")
        workflow.status = .running
        context.insert(workflow)
        try context.save()

        let service = RuntimeRecoveryService()
        let summary = try service.loadRecoverySummary(from: context)

        #expect(summary.items.count == 1)
        #expect(summary.items.first?.sourceKind == .workflow)
        #expect(summary.items.first?.sessionId == "s1")
    }

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

    @Test func markInterruptedCancelsRunningWorkflow() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let workflow = WorkflowInstance(sessionId: "s3", definitionId: "code_change", userTask: "Fix issue")
        workflow.status = .running
        context.insert(workflow)
        try context.save()

        let service = RuntimeRecoveryService()
        _ = try service.loadRecoverySummary(from: context)
        let snapshot = try #require(service.recoveryItems(for: "s3").first)

        try service.markInterrupted(snapshot, in: context)

        #expect(workflow.status == .cancelled)
        #expect(snapshot.handlingState == .interrupted)
        #expect(service.recoveryItems(for: "s3").isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Session.self,
            Message.self,
            WorkflowInstance.self,
            RecoverySnapshot.self,
            configurations: config
        )
    }
}