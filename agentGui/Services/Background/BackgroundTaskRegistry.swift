import Foundation
import SwiftData

@MainActor
final class BackgroundTaskRegistry {
    typealias SchedulerFactory = (_ identifier: String) -> any BackgroundSystemScheduler

    private let policyEngine: BackgroundTaskPolicyEngine
    private let schedulerFactory: SchedulerFactory
    private let observationService: BackgroundTaskObservationService?
    private var schedulersByIdentifier: [String: any BackgroundSystemScheduler] = [:]

    init(
        policyEngine: BackgroundTaskPolicyEngine,
        schedulerFactory: @escaping SchedulerFactory,
        observationService: BackgroundTaskObservationService? = nil
    ) {
        self.policyEngine = policyEngine
        self.schedulerFactory = schedulerFactory
        self.observationService = observationService
    }

    convenience init() {
        self.init(observationService: nil)
    }

    convenience init(observationService: BackgroundTaskObservationService?) {
        self.init(
            policyEngine: BackgroundTaskPolicyEngine(),
            schedulerFactory: { NSBackgroundSystemSchedulerAdapter(identifier: $0) },
            observationService: observationService
        )
    }

    func refresh(modelContext: ModelContext) throws {
        let tasks = try modelContext.fetch(FetchDescriptor<BackgroundAgentTask>())
        let enabledTasks = tasks.filter(\.isEnabled)
        let enabledIdentifiers = Set(enabledTasks.map(Self.schedulerIdentifier(for:)))

        for identifier in schedulersByIdentifier.keys where !enabledIdentifiers.contains(identifier) {
            schedulersByIdentifier[identifier]?.invalidate()
            schedulersByIdentifier.removeValue(forKey: identifier)
        }

        for task in enabledTasks {
            let identifier = Self.schedulerIdentifier(for: task)
            let scheduler = schedulersByIdentifier[identifier] ?? makeScheduler(for: identifier)
            let schedule = policyEngine.makeSchedule(for: task.schedulePolicy)
            scheduler.interval = schedule.interval
            scheduler.tolerance = schedule.tolerance
            scheduler.repeats = schedule.repeats
            scheduler.qualityOfService = schedule.qualityOfService
            scheduler.setHandler { _, completion in
                completion(.finished)
            }
            schedulersByIdentifier[identifier] = scheduler
            observationService?.recordRegisteredTask(for: task, schedulerIdentifier: identifier)
        }
    }

    func invalidateAll() {
        for scheduler in schedulersByIdentifier.values {
            scheduler.invalidate()
        }
        schedulersByIdentifier.removeAll()
    }

    func scheduler(for identifier: String) -> (any BackgroundSystemScheduler)? {
        schedulersByIdentifier[identifier]
    }

    static func schedulerIdentifier(for task: BackgroundAgentTask) -> String {
        "com.agentgui.background.task.\(task.taskKey)"
    }

    private func makeScheduler(for identifier: String) -> any BackgroundSystemScheduler {
        schedulerFactory(identifier)
    }
}