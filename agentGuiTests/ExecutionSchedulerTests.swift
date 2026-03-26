import Foundation
import Testing
@testable import agentGui

struct ExecutionSchedulerTests {
    @Test
    func admitsParallelBuiltInJobsAcrossDifferentSessionsWhenCapacityAllows() async {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 2)
        let firstJobID = UUID()
        let secondJobID = UUID()

        let admitted = await scheduler.admitReadyJobs([
            ExecutionSchedulingCandidate(
                sessionID: "session-a",
                jobID: firstJobID,
                providerID: .builtInAgent
            ),
            ExecutionSchedulingCandidate(
                sessionID: "session-b",
                jobID: secondJobID,
                providerID: .builtInAgent
            )
        ])

        #expect(admitted.map { $0.jobID } == [firstJobID, secondJobID])
    }

    @Test
    func rejectsSecondJobForSameSessionWhileFirstIsRunning() async {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 3)
        let firstJobID = UUID()
        let secondJobID = UUID()

        let admitted = await scheduler.admitReadyJobs([
            ExecutionSchedulingCandidate(
                sessionID: "session-a",
                jobID: firstJobID,
                providerID: .builtInAgent
            ),
            ExecutionSchedulingCandidate(
                sessionID: "session-a",
                jobID: secondJobID,
                providerID: .builtInAgent
            )
        ])

        #expect(admitted.map { $0.jobID } == [firstJobID])
    }

    @Test
    func queuesJobsWhenGlobalCapacityIsFull() async {
        let scheduler = ExecutionScheduler(maxConcurrentJobs: 1)
        let firstJobID = UUID()
        let secondJobID = UUID()

        let admitted = await scheduler.admitReadyJobs([
            ExecutionSchedulingCandidate(
                sessionID: "session-a",
                jobID: firstJobID,
                providerID: .builtInAgent
            ),
            ExecutionSchedulingCandidate(
                sessionID: "session-b",
                jobID: secondJobID,
                providerID: .builtInAgent
            )
        ])

        #expect(admitted.map { $0.jobID } == [firstJobID])
    }
}