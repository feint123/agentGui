import Foundation
import Testing
@testable import agentGui

struct SessionExecutionMailboxTests {
    @Test func mailboxKeepsSingleSessionJobsInFifoOrder() async throws {
        let mailbox = SessionExecutionMailbox(sessionID: "s1")
        let first = UUID()
        let second = UUID()

        await mailbox.enqueue(jobID: first)
        await mailbox.enqueue(jobID: second)

        #expect(await mailbox.peekNextJobID() == first)
        #expect(await mailbox.markRunning(jobID: first) == true)
        #expect(await mailbox.peekNextJobID() == second)
    }

    @Test func mailboxDoesNotStartSecondJobWhileOneIsRunning() async throws {
        let mailbox = SessionExecutionMailbox(sessionID: "s1")
        let first = UUID()
        let second = UUID()

        await mailbox.enqueue(jobID: first)
        await mailbox.enqueue(jobID: second)
        _ = await mailbox.markRunning(jobID: first)

        #expect(await mailbox.markRunning(jobID: second) == false)
        #expect(await mailbox.finishRunning(jobID: first) == true)
        #expect(await mailbox.markRunning(jobID: second) == true)
    }
}