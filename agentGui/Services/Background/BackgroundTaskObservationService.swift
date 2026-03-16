import Foundation
import SwiftData

@MainActor
final class BackgroundTaskObservationService {
    private let persistenceCoordinator: PersistenceCoordinator
    private let sink: BusinessLogSink?

    init(
        persistenceCoordinator: PersistenceCoordinator,
        sink: BusinessLogSink? = nil
    ) {
        self.persistenceCoordinator = persistenceCoordinator
        self.sink = sink
    }

    convenience init(sink: BusinessLogSink? = nil) {
        self.init(persistenceCoordinator: .shared, sink: sink)
    }

    func recordRegisteredTask(
        for task: BackgroundAgentTask,
        schedulerIdentifier: String
    ) {
        emit(
            .backgroundTaskRegistered,
            task: task,
            run: nil,
            metadata: [
                "taskKey": task.taskKey,
                "schedulerIdentifier": schedulerIdentifier
            ]
        )
    }

    @discardableResult
    func recordTriggeredRun(
        for task: BackgroundAgentTask,
        schedulerIdentifier: String,
        modelContext: ModelContext
    ) throws -> BackgroundAgentTaskRun {
        let run = BackgroundAgentTaskRun(
            taskID: task.id,
            schedulerIdentifier: schedulerIdentifier,
            status: .triggered,
            decision: .pending
        )
        modelContext.insert(run)
        try persistenceCoordinator.save(
            modelContext,
            domain: .sessionTaskState,
            userMessage: "后台任务触发记录未成功保存",
            metadata: [
                "taskKey": task.taskKey,
                "schedulerIdentifier": schedulerIdentifier
            ]
        )
        BusinessMonitor.emit(
            .backgroundTaskTriggered,
            context: .init(sessionID: task.sessionId),
            metadata: [
                "taskKey": task.taskKey,
                "schedulerIdentifier": schedulerIdentifier
            ],
            sink: sink
        )
        return run
    }

    func recordSkipped(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        reason: String?
    ) {
        append(.backgroundTaskSkipped, to: run)
        emit(
            .backgroundTaskSkipped,
            task: task,
            run: run,
            metadata: [
                "taskKey": task.taskKey,
                "reason": reason ?? "unknown"
            ]
        )
    }

    func recordDeferred(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        reason: String?
    ) {
        append(.backgroundTaskDeferred, to: run)
        emit(
            .backgroundTaskDeferred,
            task: task,
            run: run,
            metadata: [
                "taskKey": task.taskKey,
                "reason": reason ?? "unknown"
            ]
        )
    }

    func recordStarted(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun
    ) {
        append(.backgroundTaskStarted, to: run)
        emit(
            .backgroundTaskStarted,
            task: task,
            run: run,
            metadata: ["taskKey": task.taskKey]
        )
    }

    func recordCompleted(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        summary: String?
    ) {
        append(.backgroundTaskCompleted, to: run)
        updateAgentSummary(status: "completed", summary: summary, run: run)
        emit(
            .backgroundTaskCompleted,
            task: task,
            run: run,
            metadata: [
                "taskKey": task.taskKey,
                "summary": summary ?? ""
            ]
        )
    }

    func recordFailed(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun,
        summary: String
    ) {
        append(.backgroundTaskFailed, to: run)
        updateAgentSummary(status: "failed", summary: summary, run: run)
        emit(
            .backgroundTaskFailed,
            task: task,
            run: run,
            metadata: [
                "taskKey": task.taskKey,
                "summary": summary
            ]
        )
    }

    func recordPolicyAdjusted(
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun?,
        reason: String
    ) {
        if let run {
            append(.backgroundTaskPolicyAdjusted, to: run)
        }
        emit(
            .backgroundTaskPolicyAdjusted,
            task: task,
            run: run,
            metadata: [
                "taskKey": task.taskKey,
                "reason": reason
            ]
        )
    }

    private func append(
        _ event: AgentBusinessEvent,
        to run: BackgroundAgentTaskRun
    ) {
        var events = (try? JSONDecoder().decode([String].self, from: Data(run.businessEventDigestJSON.utf8))) ?? []
        events.append(event.rawValue)
        run.businessEventDigestJSON = (try? String(data: JSONEncoder().encode(events), encoding: .utf8)) ?? "[]"
    }

    private func updateAgentSummary(
        status: String,
        summary: String?,
        run: BackgroundAgentTaskRun
    ) {
        let payload: [String: String] = [
            "status": status,
            "summary": summary ?? ""
        ]
        run.agentSummaryJSON = (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? "{}"
    }

    private func emit(
        _ event: AgentBusinessEvent,
        task: BackgroundAgentTask,
        run: BackgroundAgentTaskRun?,
        metadata: [String: Any]
    ) {
        BusinessMonitor.emit(
            event,
            context: .init(
                runID: run?.id.uuidString,
                sessionID: task.sessionId
            ),
            metadata: metadata,
            sink: sink
        )
    }
}