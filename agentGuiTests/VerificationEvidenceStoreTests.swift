import XCTest
@testable import agentGui

final class VerificationEvidenceStoreTests: XCTestCase {

    func test_noEvidence_initially() async {
        let store = VerificationEvidenceStore()
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertFalse(has)
    }

    func test_recordedEvidence_isDetected() async {
        let store = VerificationEvidenceStore()
        let summary = VerificationEvidenceSummary(
            command: "swift test",
            passCount: 5,
            failCount: 0,
            failureSummary: nil,
            exitedZero: true,
            capturedAt: Date()
        )
        await store.record(summary, sessionID: "session-1")
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertTrue(has)
    }

    func test_evidence_isolation_betweenSessions() async {
        let store = VerificationEvidenceStore()
        let summary = makeSummary()
        await store.record(summary, sessionID: "session-A")
        let hasA = await store.hasEvidence(for: "session-A")
        let hasB = await store.hasEvidence(for: "session-B")
        XCTAssertTrue(hasA)
        XCTAssertFalse(hasB)
    }

    func test_clearEvidence_removesAllForSession() async {
        let store = VerificationEvidenceStore()
        await store.record(makeSummary(), sessionID: "session-1")
        await store.clearEvidence(for: "session-1")
        let has = await store.hasEvidence(for: "session-1")
        XCTAssertFalse(has)
    }

    func test_multipleRecords_allRetrieved() async {
        let store = VerificationEvidenceStore()
        await store.record(makeSummary(pass: 3), sessionID: "session-1")
        await store.record(makeSummary(pass: 7), sessionID: "session-1")
        let records = await store.evidence(for: "session-1")
        XCTAssertEqual(records.count, 2)
    }

    // MARK: - Helpers

    private func makeSummary(pass: Int = 1) -> VerificationEvidenceSummary {
        VerificationEvidenceSummary(
            command: "swift test",
            passCount: pass,
            failCount: 0,
            failureSummary: nil,
            exitedZero: true,
            capturedAt: Date()
        )
    }
}
