import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryBridgeExpanderTests {
    @Test func expanderLinksFailureFactsToRecoveryRecords() throws {
        let selected = [
            MemoryRecord.fixture(
                id: "failure-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "xcodebuild scheme failure",
                summary: "Scheme missing",
                tags: ["failed-attempt"]
            )
        ]
        let candidates = selected + [
            MemoryRecord.fixture(
                id: "recovery-1",
                layer: .task,
                kind: .working,
                scope: .session(id: "s1"),
                title: "Re-run with shared scheme",
                summary: "Mark scheme as shared before xcodebuild",
                tags: ["recovery-tip"]
            )
        ]

        let expansion = MemoryBridgeExpander().expand(selectedRecords: selected, candidateRecords: candidates)

        #expect(expansion.edges.contains { $0.sourceRecordID == "failure-1" && $0.targetRecordID == "recovery-1" })
        #expect(expansion.additionalRecords.contains { $0.id == "recovery-1" })
    }
}