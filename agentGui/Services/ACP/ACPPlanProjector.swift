import Foundation

struct ACPPlanProjector {
    func makeExecutionPlan(from snapshot: ACPPlanSnapshotDraft) -> ExecutionPlan {
        ExecutionPlan(
            goal: "ACP Agent Plan",
            steps: snapshot.entries.enumerated().map { index, entry in
                PlanStep(
                    id: "\(snapshot.remoteSessionID)-\(index)",
                    title: entry.content,
                    status: planStepStatus(from: entry.status),
                    priority: entry.priority.rawValue
                )
            },
            assumptions: [],
            successCriteria: []
        )
    }

    func makeTodoItems(from snapshot: ACPPlanSnapshotDraft) -> [TodoItem] {
        snapshot.entries.enumerated().map { index, entry in
            TodoItem(
                id: "\(snapshot.remoteSessionID)-\(index)",
                title: entry.content,
                status: todoStatus(from: entry.status)
            )
        }
    }

    private func planStepStatus(from status: ACPPlanEntryStatus) -> PlanStepStatus {
        switch status {
        case .pending:
            return .pending
        case .inProgress:
            return .inProgress
        case .completed:
            return .done
        }
    }

    private func todoStatus(from status: ACPPlanEntryStatus) -> TodoStatus {
        switch status {
        case .pending:
            return .pending
        case .inProgress:
            return .inProgress
        case .completed:
            return .done
        }
    }
}
