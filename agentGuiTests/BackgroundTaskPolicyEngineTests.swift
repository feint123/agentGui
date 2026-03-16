import Foundation
import Testing
@testable import agentGui

@MainActor
struct BackgroundTaskPolicyEngineTests {
    @Test func mapsTriggerPolicyIntoSystemSchedule() {
        let engine = BackgroundTaskPolicyEngine()
        let policy = BackgroundTaskPolicy(
            baseIntervalSeconds: 7_200,
            toleranceSeconds: 1_800,
            repeats: true,
            qualityOfService: .background
        )

        let schedule = engine.makeSchedule(for: policy)

        #expect(schedule.interval == 7_200)
        #expect(schedule.tolerance == 1_800)
        #expect(schedule.repeats)
        #expect(schedule.qualityOfService == .background)
    }

    @Test func clampsToleranceToBeStrictlyLessThanInterval() {
        let engine = BackgroundTaskPolicyEngine()
        let policy = BackgroundTaskPolicy(
            baseIntervalSeconds: 3_600,
            toleranceSeconds: 3_600,
            repeats: true,
            qualityOfService: .utility
        )

        let schedule = engine.makeSchedule(for: policy)

        #expect(schedule.interval == 3_600)
        #expect(schedule.tolerance < schedule.interval)
    }
}