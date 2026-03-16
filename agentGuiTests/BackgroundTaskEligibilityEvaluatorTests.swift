import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct BackgroundTaskEligibilityEvaluatorTests {

    @Test func cooldownTaskIsDeferredInsteadOfExecuted() {
        let task = BackgroundAgentTask.fixture(cooldownUntil: Date().addingTimeInterval(600))
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(),
            environment: .fixture()
        )

        #expect(result.decision == .`defer`)
        #expect(result.reason == "cooldownActive")
    }

    @Test func disabledTaskIsSkipped() {
        let task = BackgroundAgentTask.fixture(isEnabled: false)
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(),
            environment: .fixture()
        )

        #expect(result.decision == .skip)
        #expect(result.reason == "taskDisabled")
    }

    @Test func missingWorkspaceIsSkipped() {
        let task = BackgroundAgentTask.fixture()
        task.workspacePath = "/missing/workspace"
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(),
            environment: .fixture(existingWorkspacePaths: [])
        )

        #expect(result.decision == .skip)
        #expect(result.reason == "workspaceMissing")
    }

    @Test func networkRequiredTaskIsDeferredWhenNetworkUnavailable() {
        let task = BackgroundAgentTask.fixture()
        var policy = task.schedulePolicy
        policy.requiresNetwork = true
        task.schedulePolicy = policy
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(),
            environment: .fixture(networkAvailable: false)
        )

        #expect(result.decision == .`defer`)
        #expect(result.reason == "networkUnavailable")
    }

    @Test func externalPowerRequirementDefersTaskWhenMachineIsOnBattery() {
        let task = BackgroundAgentTask.fixture()
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(),
            environment: .fixture(requiresExternalPower: true, externalPowerConnected: false)
        )

        #expect(result.decision == .`defer`)
        #expect(result.reason == "externalPowerRequired")
    }

    @Test func taskOutsideAllowedWeekdaysIsDeferred() {
        let task = BackgroundAgentTask.fixture()
        var policy = task.schedulePolicy
        policy.allowedWeekdays = [3]
        task.schedulePolicy = policy
        let evaluator = BackgroundTaskEligibilityEvaluator()
        let calendar = Calendar.autoupdatingCurrent
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 12))!

        let result = evaluator.evaluate(
            task: task,
            now: now,
            environment: .fixture()
        )

        #expect(result.decision == .`defer`)
        #expect(result.reason == "outsideAllowedWeekdays")
    }

    @Test func taskOutsideAllowedHourRangeIsDeferred() {
        let task = BackgroundAgentTask.fixture()
        var policy = task.schedulePolicy
        policy.allowedHourRange = 10...18
        task.schedulePolicy = policy
        let evaluator = BackgroundTaskEligibilityEvaluator()

        let result = evaluator.evaluate(
            task: task,
            now: Date(timeIntervalSince1970: 1_710_096_000),
            environment: .fixture()
        )

        #expect(result.decision == .`defer`)
        #expect(result.reason == "outsideAllowedHours")
    }

    @Test func observationServiceCreatesTriggeredRunAndEmitsBusinessEvent() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BackgroundAgentTask.self,
            BackgroundAgentTaskRun.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let task = BackgroundAgentTask.fixture(taskKey: "nightly")
        context.insert(task)
        try context.save()

        let sink = InMemoryBusinessLogSink()
        let service = BackgroundTaskObservationService(sink: sink)

        let run = try service.recordTriggeredRun(
            for: task,
            schedulerIdentifier: BackgroundTaskRegistry.schedulerIdentifier(for: task),
            modelContext: context
        )

        let runs = try context.fetch(FetchDescriptor<BackgroundAgentTaskRun>())
        #expect(runs.count == 1)
        #expect(run.status == .triggered)
        #expect(sink.events.map(\.event) == [.backgroundTaskTriggered])
    }
}