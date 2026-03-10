import Foundation
import Testing
@testable import agentGui

@MainActor
struct TaskMemoryRecordFactoryTests {
    @Test func factoryBuildsSessionScopedRecordsForConfirmedFactsAndFailures() async throws {
        let timestamp = Date(timeIntervalSince1970: 100)

        let records = TaskMemoryRecordFactory().makeRecords(
            sessionId: "session-1",
            confirmedFacts: ["Build uses xcodebuild"],
            attemptedActions: ["Ran xcodebuild test"],
            failedAttempts: [FailedAttempt(action: "Run tests", reason: "Scheme missing")],
            pendingQuestions: ["Which scheme should run?"],
            verificationEntries: [VerificationEntry(item: "CI command", status: "verified")],
            timestamp: timestamp
        )

        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.scope == .session(id: "session-1") })
        #expect(records.allSatisfy { $0.source == .taskMemory })
        #expect(records.contains { $0.tags.contains("confirmed-fact") && $0.verificationStatus == .verified })
        #expect(records.contains { $0.tags.contains("attempt") && $0.verificationStatus == .partial })
        #expect(records.contains { $0.tags.contains("failed-attempt") && $0.verificationStatus == .failed })
        #expect(records.contains { $0.tags.contains("pending") && $0.verificationStatus == .unverified })
        #expect(records.contains { $0.tags.contains("verification-entry") && $0.summary == "verified" })
    }
}