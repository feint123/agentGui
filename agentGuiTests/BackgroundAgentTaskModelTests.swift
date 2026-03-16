import Foundation
import Testing
@testable import agentGui

@MainActor
struct BackgroundAgentTaskModelTests {

    @Test func taskPoliciesRoundTripThroughJSON() throws {
        let policy = BackgroundTaskPolicy(
            baseIntervalSeconds: 21_600,
            toleranceSeconds: 3_600,
            repeats: true,
            qualityOfService: .utility
        )

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(BackgroundTaskPolicy.self, from: data)

        #expect(decoded.baseIntervalSeconds == 21_600)
        #expect(decoded.toleranceSeconds == 3_600)
        #expect(decoded.repeats)
        #expect(decoded.qualityOfService == .utility)
    }

    @Test func taskAndRunFixturesProvideStableDefaults() {
        let task = BackgroundAgentTask(
            taskKey: "repo-daily-summary",
            title: "日报",
            sessionId: "session-1",
            taskPrompt: "生成日报"
        )
        let run = BackgroundAgentTaskRun(taskID: task.id, schedulerIdentifier: "com.agentgui.background.task.repo-daily-summary")

        #expect(task.taskKey == "repo-daily-summary")
        #expect(task.isEnabled)
        #expect(task.schedulePolicy.baseIntervalSeconds >= 600)
        #expect(task.executionPolicy.maxTurns > 0)
        #expect(run.status == .triggered)
        #expect(run.decision == .pending)
    }

    @Test func appSettingsProvideBackgroundDefaults() {
        let settings = AppSettings()

        #expect(settings.backgroundAgentEnabled == false)
        #expect(settings.backgroundAgentDefaultQoS == "utility")
        #expect(settings.backgroundAgentMaximumConcurrentRuns == 1)
        #expect(settings.backgroundAgentObservationRetentionDays == 30)
    }

    @Test func appSchemaIncludesBackgroundTaskModels() {
        #expect(PersistenceSchema.sharedModelTypeNames.contains("BackgroundAgentTask"))
        #expect(PersistenceSchema.sharedModelTypeNames.contains("BackgroundAgentTaskRun"))
    }
}