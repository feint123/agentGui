import Foundation
import Testing
@testable import agentGui

struct ExecutionSchedulerTests {
    @Test func schedulerCanAdmitJobsFromDifferentSessionsWithoutBreakingPerSessionSerialization() async throws {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let jobA1 = ExecutionSchedulingCandidate(sessionID: "a", jobID: UUID(), runtimeScope: nil)
        let jobB1 = ExecutionSchedulingCandidate(sessionID: "b", jobID: UUID(), runtimeScope: nil)
        let jobA2 = ExecutionSchedulingCandidate(sessionID: "a", jobID: UUID(), runtimeScope: nil)

        let firstAdmission = await scheduler.admitReadyJobs([jobA1, jobB1])
        let blockedAdmission = await scheduler.admitReadyJobs([jobA2])

        #expect(firstAdmission == [jobA1, jobB1])
        #expect(blockedAdmission.isEmpty)

        await scheduler.markFinished(jobID: jobA1.jobID, sessionID: jobA1.sessionID)

        let resumedAdmission = await scheduler.admitReadyJobs([jobA2])
        #expect(resumedAdmission == [jobA2])
    }

    @Test func schedulerKeepsExternalACPRuntimeSerializedAcrossSessions() async throws {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let jobA = ExecutionSchedulingCandidate(sessionID: "a", jobID: UUID(), runtimeScope: .externalACP)
        let jobB = ExecutionSchedulingCandidate(sessionID: "b", jobID: UUID(), runtimeScope: .externalACP)

        let admitted = await scheduler.admitReadyJobs([jobA, jobB])

        #expect(admitted == [jobA])
    }

    @Test func schedulerAllowsMixedRuntimeScopesWithinGlobalConcurrencyLimit() async throws {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let builtInJob = ExecutionSchedulingCandidate(sessionID: "built-in", jobID: UUID(), runtimeScope: nil)
        let externalJob = ExecutionSchedulingCandidate(sessionID: "external", jobID: UUID(), runtimeScope: .externalACP)

        let admitted = await scheduler.admitReadyJobs([builtInJob, externalJob])

        #expect(admitted == [builtInJob, externalJob])
    }

    @Test func schedulerKeepsBuiltInRuntimeSerializedAcrossSessions() async throws {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let firstBuiltIn = ExecutionSchedulingCandidate(sessionID: "session-a", jobID: UUID(), runtimeScope: .builtIn)
        let secondBuiltIn = ExecutionSchedulingCandidate(sessionID: "session-b", jobID: UUID(), runtimeScope: .builtIn)

        let admitted = await scheduler.admitReadyJobs([firstBuiltIn, secondBuiltIn])

        #expect(admitted == [firstBuiltIn])
    }
}