import Foundation

actor BashTaskRegistry {
    private var snapshotsByTaskID: [String: TerminalTaskSnapshot] = [:]
    private var eventsByTaskID: [String: [TerminalTaskEvent]] = [:]

    func createTask(_ snapshot: TerminalTaskSnapshot) {
        snapshotsByTaskID[snapshot.id] = snapshot
    }

    func upsert(_ snapshot: TerminalTaskSnapshot) {
        snapshotsByTaskID[snapshot.id] = snapshot
    }

    func snapshot(taskId: String) -> TerminalTaskSnapshot? {
        snapshotsByTaskID[taskId]
    }

    func updateStatus(taskId: String, status: TerminalTaskStatus, endedAt: Date? = nil) {
        guard var snapshot = snapshotsByTaskID[taskId] else { return }
        snapshot.status = status
        if let endedAt {
            snapshot.endedAt = endedAt
        }
        snapshotsByTaskID[taskId] = snapshot
    }

    func appendEvent(_ event: TerminalTaskEvent) {
        eventsByTaskID[event.taskId, default: []].append(event)
    }

    func events(taskId: String) -> [TerminalTaskEvent] {
        eventsByTaskID[taskId, default: []]
    }

    func activeBackgroundTasks() -> [TerminalTaskSnapshot] {
        snapshotsByTaskID.values
            .filter { $0.status == .runningBackground }
            .sorted { $0.id < $1.id }
    }

    func markTaskComplete(taskId: String, exitCode: Int? = nil, at endedAt: Date = Date()) {
        guard var snapshot = snapshotsByTaskID[taskId] else { return }
        snapshot.status = exitCode == nil || exitCode == 0 ? .completed : .failed
        snapshot.endedAt = endedAt
        snapshotsByTaskID[taskId] = snapshot
    }
}