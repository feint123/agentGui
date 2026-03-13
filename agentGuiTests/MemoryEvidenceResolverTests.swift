import Foundation
import Testing
@testable import agentGui

@MainActor
struct MemoryEvidenceResolverTests {
    @Test func resolverCountsEvidenceDereferencesFromSelectedRecords() throws {
        let selected = [
            MemoryRecord.fixture(
                id: "record-1",
                title: "Known failure",
                evidenceAnchors: [
                    MemoryEvidenceAnchor(kind: .toolCall, identifier: "tool-1", summary: "Ran xcodebuild"),
                    MemoryEvidenceAnchor(kind: .file, identifier: "Package.swift", summary: "Updated package config")
                ]
            )
        ]

        let result = MemoryEvidenceResolver().resolve(for: selected)

        #expect(result.dereferenceCount == 2)
        #expect(result.summaries.contains { $0.contains("tool-1") })
    }
}