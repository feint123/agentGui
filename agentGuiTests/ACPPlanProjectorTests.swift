import Foundation
import Testing
@testable import agentGui

struct ACPPlanProjectorTests {
    @Test func makeTodoItemsMapsStatuses() {
        let snapshot = ACPPlanSnapshotDraft(
            providerID: .openCodeCLI,
            remoteSessionID: "remote-1",
            entries: [
                ACPPlanEntry(content: "Inspect code", priority: .high, status: .pending),
                ACPPlanEntry(content: "Write tests", priority: .medium, status: .inProgress),
                ACPPlanEntry(content: "Ship feature", priority: .low, status: .completed)
            ]
        )

        let todos = ACPPlanProjector().makeTodoItems(from: snapshot)

        #expect(todos.map(\.title) == ["Inspect code", "Write tests", "Ship feature"])
        #expect(todos.map(\.status) == [.pending, .inProgress, .done])
    }

    @Test func makeExecutionPlanPreservesPriority() {
        let snapshot = ACPPlanSnapshotDraft(
            providerID: .openCodeCLI,
            remoteSessionID: "remote-2",
            entries: [
                ACPPlanEntry(content: "Inspect code", priority: .high, status: .inProgress)
            ]
        )

        let plan = ACPPlanProjector().makeExecutionPlan(from: snapshot)

        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].title == "Inspect code")
        #expect(plan.steps[0].status == .inProgress)
        #expect(plan.steps[0].priority == "high")
    }

    @Test func makeTodoItemsReturnsEmptyForEmptyPlan() {
        let snapshot = ACPPlanSnapshotDraft(
            providerID: .openCodeCLI,
            remoteSessionID: "remote-3",
            entries: []
        )

        let todos = ACPPlanProjector().makeTodoItems(from: snapshot)
        let plan = ACPPlanProjector().makeExecutionPlan(from: snapshot)

        #expect(todos.isEmpty)
        #expect(plan.steps.isEmpty)
    }
}
