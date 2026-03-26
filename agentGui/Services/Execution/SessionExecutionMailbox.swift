import Foundation

actor SessionExecutionMailbox {
    let sessionID: String

    private var queuedJobIDs: [UUID] = []
    private var runningJobID: UUID?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func enqueue(jobID: UUID) {
        queuedJobIDs.append(jobID)
    }

    func peekNextJobID() -> UUID? {
        queuedJobIDs.first
    }

    func discardQueuedJob(jobID: UUID) -> Bool {
        guard let index = queuedJobIDs.firstIndex(of: jobID) else {
            return false
        }

        queuedJobIDs.remove(at: index)
        return true
    }

    func markRunning(jobID: UUID) -> Bool {
        guard runningJobID == nil, queuedJobIDs.first == jobID else {
            return false
        }

        runningJobID = jobID
        queuedJobIDs.removeFirst()
        return true
    }

    func finishRunning(jobID: UUID) -> Bool {
        guard runningJobID == jobID else {
            return false
        }

        runningJobID = nil
        return true
    }
}