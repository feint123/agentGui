import Foundation
import Testing
@testable import agentGui

struct StructuredDiffEngineTests {
    @Test func structuredDiffCarriesMultipleHunksAndSummary() {
        let diff = StructuredFileDiff(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            summary: .init(additions: 2, deletions: 1, unchangedPrefixLines: 5, unchangedSuffixLines: 3),
            hunks: [
                .init(
                    id: "hunk-1",
                    oldStart: 6,
                    oldCount: 2,
                    newStart: 6,
                    newCount: 3,
                    lines: [
                        .context(oldLine: 6, newLine: 6, text: "context"),
                        .deletion(oldLine: 7, text: "old"),
                        .addition(newLine: 7, text: "new")
                    ]
                )
            ],
            renderPolicy: .unified
        )

        #expect(diff.summary.additions == 2)
        #expect(diff.summary.deletions == 1)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].oldStart == 6)
        #expect(diff.hunks[0].newCount == 3)
    }

    @Test func engineBuildsTwoHunksForSeparatedEdits() throws {
        let oldText = ["a", "b", "c", "d", "e", "f", "g", "h"].joined(separator: "\n")
        let newText = ["a", "b2", "c", "d", "e", "f", "g2", "h"].joined(separator: "\n")

        let diff = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            baseContent: oldText,
            stagedContent: newText,
            contextLines: 1,
            interHunkContext: 0
        )

        #expect(diff.hunks.count == 2)
        #expect(diff.summary.additions == 2)
        #expect(diff.summary.deletions == 2)
    }

    @Test func engineBuildsSingleCompactHunkForSingleLineReplacement() throws {
        let diff = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            baseContent: ["one", "two", "three"].joined(separator: "\n"),
            stagedContent: ["one", "two changed", "three"].joined(separator: "\n"),
            contextLines: 1,
            interHunkContext: 0
        )

        #expect(diff.hunks.count == 1)
        #expect(diff.summary.additions == 1)
        #expect(diff.summary.deletions == 1)
        #expect(diff.hunks[0].lines.contains { line in
            if case .context(oldLine: 1, newLine: 1, text: "one") = line {
                return true
            }
            return false
        })
    }

    @Test func engineBuildsAdditionAndDeletionSummaries() throws {
        let added = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .add,
            baseContent: nil,
            stagedContent: ["new", "content"].joined(separator: "\n"),
            contextLines: 3,
            interHunkContext: 0
        )
        #expect(added.summary.additions == 2)
        #expect(added.summary.deletions == 0)

        let deleted = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .delete,
            baseContent: ["old", "content"].joined(separator: "\n"),
            stagedContent: nil,
            contextLines: 3,
            interHunkContext: 0
        )
        #expect(deleted.summary.additions == 0)
        #expect(deleted.summary.deletions == 2)
    }

    @Test func engineFusesNearbyEditsIntoSingleHunk() throws {
        let oldText = ["a", "b", "c", "d", "e"].joined(separator: "\n")
        let newText = ["a", "b1", "c", "d1", "e"].joined(separator: "\n")

        let diff = try StructuredDiffEngine().build(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            baseContent: oldText,
            stagedContent: newText,
            contextLines: 1,
            interHunkContext: 1
        )

        #expect(diff.hunks.count == 1)
    }
}