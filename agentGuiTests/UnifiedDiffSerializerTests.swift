import Foundation
import Testing
@testable import agentGui

struct UnifiedDiffSerializerTests {
    @Test func serializerRendersTwoUnifiedDiffHunks() {
        let diff = StructuredFileDiff.fixtureWithTwoHunks()

        let text = UnifiedDiffSerializer.serialize(diff)

        #expect(text.contains("--- a/README.md"))
        #expect(text.contains("+++ b/README.md"))
        #expect(text.components(separatedBy: "@@").count > 4)
    }

    @Test func serializerRendersNoNewlineMarker() {
        let diff = StructuredFileDiff(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            summary: .init(additions: 1, deletions: 1, unchangedPrefixLines: 0, unchangedSuffixLines: 0),
            hunks: [
                .init(
                    id: "hunk-1",
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                        .deletion(oldLine: 1, text: "old"),
                        .addition(newLine: 1, text: "new"),
                        .noNewlineMarker
                    ]
                )
            ],
            renderPolicy: .unified
        )

        let text = UnifiedDiffSerializer.serialize(diff)

        #expect(text.contains("\\ No newline at end of file"))
    }
}

private extension StructuredFileDiff {
    static func fixtureWithTwoHunks() -> StructuredFileDiff {
        StructuredFileDiff(
            relativePath: "README.md",
            absolutePath: "/tmp/README.md",
            kind: .modify,
            summary: .init(additions: 2, deletions: 2, unchangedPrefixLines: 1, unchangedSuffixLines: 1),
            hunks: [
                .init(
                    id: "hunk-1",
                    oldStart: 2,
                    oldCount: 2,
                    newStart: 2,
                    newCount: 2,
                    lines: [
                        .context(oldLine: 2, newLine: 2, text: "before"),
                        .deletion(oldLine: 3, text: "old-1"),
                        .addition(newLine: 3, text: "new-1")
                    ]
                ),
                .init(
                    id: "hunk-2",
                    oldStart: 8,
                    oldCount: 2,
                    newStart: 8,
                    newCount: 2,
                    lines: [
                        .context(oldLine: 8, newLine: 8, text: "middle"),
                        .deletion(oldLine: 9, text: "old-2"),
                        .addition(newLine: 9, text: "new-2")
                    ]
                )
            ],
            renderPolicy: .unified
        )
    }
}