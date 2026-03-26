import Foundation

actor ExecutionScheduler {
    private let maxConcurrentJobs: Int
    private var runningJobsBySessionID: [String: UUID] = [:]
    private var runningProviderIDsBySessionID: [String: ConversationExecutionProviderID] = [:]

    init(maxConcurrentJobs: Int) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
    }

    func admitReadyJobs(_ candidates: [ExecutionSchedulingCandidate]) -> [ExecutionSchedulingCandidate] {
        guard !candidates.isEmpty else { return [] }

        var admitted: [ExecutionSchedulingCandidate] = []
        var reservedSessionIDs = Set<String>()
        var reservedSessionCountsByProviderID: [ConversationExecutionProviderID: Int] = [:]

        for candidate in candidates {
            guard runningJobsBySessionID.count + admitted.count < maxConcurrentJobs else {
                break
            }
            guard runningJobsBySessionID[candidate.sessionID] == nil else {
                continue
            }
            guard reservedSessionIDs.insert(candidate.sessionID).inserted else {
                continue
            }
            let providerSessionCount = runningProviderIDsBySessionID.values.filter { $0 == candidate.providerID }.count
            let reservedProviderSessionCount = reservedSessionCountsByProviderID[candidate.providerID, default: 0]
            guard providerSessionCount + reservedProviderSessionCount < candidate.capacityPolicy.maxConcurrentSessions else {
                reservedSessionIDs.remove(candidate.sessionID)
                continue
            }

            admitted.append(candidate)
            reservedSessionCountsByProviderID[candidate.providerID, default: 0] += 1
        }

        for candidate in admitted {
            runningJobsBySessionID[candidate.sessionID] = candidate.jobID
            runningProviderIDsBySessionID[candidate.sessionID] = candidate.providerID
        }

        return admitted
    }

    func markFinished(jobID: UUID, sessionID: String) {
        guard runningJobsBySessionID[sessionID] == jobID else {
            return
        }

        runningJobsBySessionID.removeValue(forKey: sessionID)
        runningProviderIDsBySessionID.removeValue(forKey: sessionID)
    }
}