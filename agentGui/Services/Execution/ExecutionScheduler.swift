import Foundation

actor ExecutionScheduler {
    private let maxConcurrentJobs: Int
    private var runningJobsBySessionID: [String: UUID] = [:]
    private var runningProviderReferencesBySessionID: [String: ExecutionProviderReference] = [:]

    init(maxConcurrentJobs: Int) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
    }

    func admitReadyJobs(_ candidates: [ExecutionSchedulingCandidate]) -> [ExecutionSchedulingCandidate] {
        guard !candidates.isEmpty else { return [] }

        var admitted: [ExecutionSchedulingCandidate] = []
        var reservedSessionIDs = Set<String>()
        var reservedSessionCountsByProviderReference: [String: Int] = [:]

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
            let providerKey = candidate.providerReference.persistedValue
            let providerSessionCount = runningProviderReferencesBySessionID.values.filter {
                $0 == candidate.providerReference
            }.count
            let reservedProviderSessionCount = reservedSessionCountsByProviderReference[providerKey, default: 0]
            guard providerSessionCount + reservedProviderSessionCount < candidate.capacityPolicy.maxConcurrentSessions else {
                reservedSessionIDs.remove(candidate.sessionID)
                continue
            }

            admitted.append(candidate)
            reservedSessionCountsByProviderReference[providerKey, default: 0] += 1
        }

        for candidate in admitted {
            runningJobsBySessionID[candidate.sessionID] = candidate.jobID
            runningProviderReferencesBySessionID[candidate.sessionID] = candidate.providerReference
        }

        return admitted
    }

    func markFinished(jobID: UUID, sessionID: String) {
        guard runningJobsBySessionID[sessionID] == jobID else {
            return
        }

        runningJobsBySessionID.removeValue(forKey: sessionID)
        runningProviderReferencesBySessionID.removeValue(forKey: sessionID)
    }
}