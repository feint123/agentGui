import Foundation

struct BackgroundEligibilityResult: Equatable, Sendable {
    var decision: BackgroundExecutionDecision
    var reason: String?

    static let run = BackgroundEligibilityResult(decision: .run, reason: nil)
}

struct BackgroundExecutionEnvironment: Equatable, Sendable {
    var shouldDefer: Bool
    var runningTaskKeys: Set<String>
    var existingWorkspacePaths: Set<String>
    var runningTaskCount: Int
    var maximumConcurrentRuns: Int?
    var requiresExternalPower: Bool
    var externalPowerConnected: Bool?
    var networkAvailable: Bool?

    init(
        shouldDefer: Bool = false,
        runningTaskKeys: Set<String> = [],
        existingWorkspacePaths: Set<String> = [],
        runningTaskCount: Int = 0,
        maximumConcurrentRuns: Int? = nil,
        requiresExternalPower: Bool = false,
        externalPowerConnected: Bool? = nil,
        networkAvailable: Bool? = nil
    ) {
        self.shouldDefer = shouldDefer
        self.runningTaskKeys = runningTaskKeys
        self.existingWorkspacePaths = Set(existingWorkspacePaths.map(Self.normalizeWorkspacePath))
        self.runningTaskCount = runningTaskCount
        self.maximumConcurrentRuns = maximumConcurrentRuns
        self.requiresExternalPower = requiresExternalPower
        self.externalPowerConnected = externalPowerConnected
        self.networkAvailable = networkAvailable
    }

    static func fixture(
        shouldDefer: Bool = false,
        runningTaskKeys: Set<String> = [],
        existingWorkspacePaths: Set<String> = [],
        runningTaskCount: Int = 0,
        maximumConcurrentRuns: Int? = nil,
        requiresExternalPower: Bool = false,
        externalPowerConnected: Bool? = nil,
        networkAvailable: Bool? = nil
    ) -> BackgroundExecutionEnvironment {
        BackgroundExecutionEnvironment(
            shouldDefer: shouldDefer,
            runningTaskKeys: runningTaskKeys,
            existingWorkspacePaths: existingWorkspacePaths,
            runningTaskCount: runningTaskCount,
            maximumConcurrentRuns: maximumConcurrentRuns,
            requiresExternalPower: requiresExternalPower,
            externalPowerConnected: externalPowerConnected,
            networkAvailable: networkAvailable
        )
    }

    nonisolated private static func normalizeWorkspacePath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

@MainActor
struct BackgroundTaskEligibilityEvaluator {
    func evaluate(
        task: BackgroundAgentTask,
        now: Date,
        environment: BackgroundExecutionEnvironment
    ) -> BackgroundEligibilityResult {
        let policy = task.schedulePolicy.sanitizedForScheduling

        guard task.isEnabled else {
            return BackgroundEligibilityResult(decision: .skip, reason: "taskDisabled")
        }

        if let cooldownUntil = task.cooldownUntil, cooldownUntil > now {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "cooldownActive")
        }

        if environment.requiresExternalPower,
           environment.externalPowerConnected == false {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "externalPowerRequired")
        }

        if !policy.allowedWeekdays.isEmpty {
            let weekday = Calendar.autoupdatingCurrent.component(.weekday, from: now)
            if !policy.allowedWeekdays.contains(weekday) {
                return BackgroundEligibilityResult(decision: .`defer`, reason: "outsideAllowedWeekdays")
            }
        }

        if let allowedHourRange = policy.allowedHourRange {
            let hour = Calendar.autoupdatingCurrent.component(.hour, from: now)
            if !allowedHourRange.contains(hour) {
                return BackgroundEligibilityResult(decision: .`defer`, reason: "outsideAllowedHours")
            }
        }

        if policy.requiresNetwork, environment.networkAvailable == false {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "networkUnavailable")
        }

        if environment.shouldDefer {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "systemRequestedDefer")
        }

        if let maximumConcurrentRuns = environment.maximumConcurrentRuns,
           environment.runningTaskCount >= max(1, maximumConcurrentRuns) {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "maximumConcurrencyReached")
        }

        if environment.runningTaskKeys.contains(task.taskKey) {
            return BackgroundEligibilityResult(decision: .`defer`, reason: "taskAlreadyRunning")
        }

          if let workspacePath = task.workspacePath,
              !workspacePath.isEmpty,
              !environment.existingWorkspacePaths.contains((workspacePath as NSString).standardizingPath) {
            return BackgroundEligibilityResult(decision: .skip, reason: "workspaceMissing")
        }

        return .run
    }
}