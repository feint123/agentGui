import Foundation

struct MemoryAdmissionFeatureExtractor {
    // Keep the first version deterministic and cheap so governance remains auditable.
    func extract(from candidate: MemoryCandidate) -> MemoryAdmissionFeatureVector {
        let normalizedConfidence = candidate.confidence.clamped(to: 0...1)
        let taskRelevance = inferredTaskRelevance(for: candidate)
        let novelty = candidate.tags.isEmpty ? 0.5 : 0.7
        let verificationSupport = candidate.verificationStatus == .verified ? 1 : 0
        let privacyRisk = candidate.scope == .user ? 0.2 : 0.0
        let driftRisk = candidate.verificationStatus == .unverified ? 0.4 : 0.1

        return MemoryAdmissionFeatureVector(
            futureUtility: inferredFutureUtility(for: candidate),
            factualConfidence: normalizedConfidence,
            novelty: novelty,
            temporalRecency: 1.0,
            taskRelevance: taskRelevance,
            verificationSupport: verificationSupport,
            privacyRisk: privacyRisk,
            driftRisk: driftRisk
        )
    }

    private func inferredFutureUtility(for candidate: MemoryCandidate) -> Double {
        switch candidate.layer {
        case .instant:
            return 0.4
        case .semantic:
            return 0.8
        case .task, .working:
            return 0.75
        case .episodic:
            return 0.6
        case .proceduralArchive:
            return 0.7
        }
    }

    private func inferredTaskRelevance(for candidate: MemoryCandidate) -> Double {
        switch (candidate.domainProfile, candidate.layer, candidate.kind) {
        case ("coding-task", .task, .working):
            return 1.0
        case ("coding-task", .semantic, _):
            return 0.8
        case ("creative-writing", .semantic, .semantic):
            return 0.7
        default:
            return 0.6
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}