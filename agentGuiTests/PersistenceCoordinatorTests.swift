import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct PersistenceCoordinatorTests {

    @Test func successfulSaveDoesNotRecordFailure() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var recordedFailures: [PersistenceFailureRecord] = []
        let coordinator = PersistenceCoordinator(
            saveOperation: { _ in },
            failureSink: { recordedFailures.append($0) }
        )

        try coordinator.save(
            context,
            domain: .settings,
            userMessage: "设置保存失败"
        )

        #expect(recordedFailures.isEmpty)
        #expect(coordinator.lastFailure == nil)
        #expect(coordinator.lastFailureSummary == nil)
    }

    @Test func recordsStructuredFailureForCoreWorkflowSave() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var recordedFailures: [PersistenceFailureRecord] = []
        let coordinator = PersistenceCoordinator(
            saveOperation: { _ in throw CocoaError(.fileWriteNoPermission) },
            failureSink: { recordedFailures.append($0) }
        )

        await #expect(throws: PersistenceCoordinator.SaveError.self) {
            try coordinator.save(
                context,
                domain: .workflow,
                userMessage: "未能保存工作流状态",
                metadata: ["sessionId": "session-1"]
            )
        }

        let failure = try #require(recordedFailures.first)
        #expect(recordedFailures.count == 1)
        #expect(failure.domain == .workflow)
        #expect(failure.category == .permissionDenied)
        #expect(failure.isCritical == true)
        #expect(failure.userMessage == "未能保存工作流状态")
        #expect(coordinator.lastFailureSummary?.contains("未能保存工作流状态") == true)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: AppSettings.self,
            PersistenceFailureRecord.self,
            configurations: config
        )
    }
}