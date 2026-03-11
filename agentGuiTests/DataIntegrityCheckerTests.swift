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

    @Test func flagsRunningWorkflowWithoutProgressRecords() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let workflow = WorkflowInstance(sessionId: "s2", definitionId: "code_change", userTask: "Broken workflow")
        workflow.status = .running
        context.insert(workflow)
        try context.save()

        let checker = DataIntegrityChecker()
        let report = try checker.runLightweightChecks(in: context)

        #expect(report.issues.contains { $0.kind == .invalidWorkflowState })
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Session.self,
            Message.self,
            ToolCall.self,
            WorkflowInstance.self,
            WorkflowMessageRecord.self,
            WorkflowActivationRecord.self,
            IntegrityIssue.self,
            configurations: config
        )
    }
}