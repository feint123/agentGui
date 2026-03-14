import Foundation
import Testing
@testable import agentGui

@MainActor
struct UnifiedMemoryFileStoreAdapterTests {
    @Test func fileStorePersistsAndReadsScopedRecords() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let scope = MemoryScope.session(id: "session-store")
        let explanation = MemoryAdmissionExplanation(
            score: MemoryAdmissionScore(total: 0.88, route: .background),
            featureVector: MemoryAdmissionFeatureVector(
                decisionDelta: 0.74,
                transferability: 0.68,
                evidenceStrength: 0.9,
                decayResistance: 0.72,
                privacyRisk: 0.0,
                confidenceSignal: 0.9
            ),
            assessment: MemoryDecisionImpactAssessment(
                decisionDelta: MemoryAdmissionGateResult(passes: true, value: 0.74, rationale: "changes next verification step"),
                transfer: MemoryAdmissionGateResult(passes: true, value: 0.68, rationale: "reusable across coding tasks"),
                evidence: MemoryAdmissionGateResult(passes: true, value: 0.9, rationale: "tool evidence attached"),
                decay: MemoryAdmissionGateResult(passes: true, value: 0.72, rationale: "stable enough for stored memory")
            ),
            reasons: ["recent verified task context"]
        )
        let record = MemoryRecord.fixture(
            id: "record-a",
            layer: .task,
            kind: .working,
            scope: scope,
            title: "Build failure",
            evidenceAnchors: [
                MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran build")
            ],
            admissionExplanation: explanation
        )

        _ = try store.persist(record: record)

        let records = try store.records(for: scope)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(records.first?.layer == .task)
        #expect(records.first?.evidenceAnchors.first?.identifier == "tool-1")
        #expect(records.first?.admissionExplanation?.reasons == ["recent verified task context"])
    }

    @Test func fileStoreHidesArchivedRecordsByDefaultAndSupportsReplaceAndTouch() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let scope = MemoryScope.project(id: "project-store")
        let oldRecord = MemoryRecord.fixture(
            id: "record-old",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "Old rule"
        )
        let newRecord = MemoryRecord.fixture(
            id: "record-new",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "New rule"
        )

        _ = try store.persist(record: oldRecord)
        _ = try store.replace(recordID: oldRecord.id, with: newRecord)
        let touchedAt = Date(timeIntervalSince1970: 200)
        _ = try store.touch(recordID: newRecord.id, accessedAt: touchedAt)
        _ = try store.archive(recordID: oldRecord.id, reason: .superseded)

        let visible = try store.records(for: scope)
        #expect(visible.count == 1)
        #expect(visible.first?.id == newRecord.id)
        #expect(visible.first?.lastAccessedAt == touchedAt)

        let allRecords = try store.records(for: scope, includeArchived: true)
        let archived = try #require(allRecords.first(where: { $0.id == oldRecord.id }))
        #expect(archived.retentionPolicy == .archiveOnly)
        #expect(archived.supersededBy == newRecord.id)
    }

    @Test func allRecordsIgnoresRuntimeSnapshotFiles() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
        let snapshotStore = MemoryRuntimeSnapshotStore(baseDirectory: baseDirectory)
        let record = MemoryRecord.fixture(
            id: "record-visible",
            layer: .task,
            kind: .working,
            scope: .session(id: "session-visible"),
            title: "Visible record"
        )

        _ = try store.persist(record: record)
        try snapshotStore.save(.fixture(id: "snapshot-1", sessionId: "s1", threadId: "t1"))

        let allRecords = try store.allRecords(includeArchived: true)

        #expect(allRecords.count == 1)
        #expect(allRecords.first?.id == "record-visible")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}