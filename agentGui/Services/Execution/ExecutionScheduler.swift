import Foundation

actor ExecutionScheduler {
    private let maxConcurrentJobs: Int
    private var runningJobsBySessionID: [String: UUID] = [:]
    private var runningRuntimeScopesBySessionID: [String: ConversationExecutionRuntimeScope] = [:]

    init(maxConcurrentJobs: Int) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
    }

    func admitReadyJobs(_ candidates: [ExecutionSchedulingCandidate]) -> [ExecutionSchedulingCandidate] {
        guard !candidates.isEmpty else { return [] }

        var admitted: [ExecutionSchedulingCandidate] = []
        var reservedSessionIDs = Set<String>()
        var reservedRuntimeScopes = Set<ConversationExecutionRuntimeScope>()

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
            if let runtimeScope = candidate.runtimeScope {
                guard runningRuntimeScopesBySessionID.values.contains(runtimeScope) == false else {
                    continue
                }
                guard reservedRuntimeScopes.insert(runtimeScope).inserted else {
                    continue
                }
            }

            admitted.append(candidate)
        }

        for candidate in admitted {
            runningJobsBySessionID[candidate.sessionID] = candidate.jobID
            if let runtimeScope = candidate.runtimeScope {
                runningRuntimeScopesBySessionID[candidate.sessionID] = runtimeScope
            }
        }

        return admitted
    }

    func markFinished(jobID: UUID, sessionID: String) {
        guard runningJobsBySessionID[sessionID] == jobID else {
            return
        }

        runningJobsBySessionID.removeValue(forKey: sessionID)
        runningRuntimeScopesBySessionID.removeValue(forKey: sessionID)
    }
}