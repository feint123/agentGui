import Foundation

struct BackgroundTaskPolicyEngine {
    func makeSchedule(for policy: BackgroundTaskPolicy) -> BackgroundSystemSchedule {
        let sanitized = policy.sanitizedForScheduling
        return BackgroundSystemSchedule(
            interval: sanitized.baseIntervalSeconds,
            tolerance: sanitized.toleranceSeconds,
            repeats: sanitized.repeats,
            qualityOfService: sanitized.qualityOfService
        )
    }
}