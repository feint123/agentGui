import XCTest
@testable import agentGui

final class FileReferencePillSnapshotTests: XCTestCase {

    // MARK: - fromStructured preserves metadata

    func test_fromStructured_preservesDisplayName() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/ClaudeService.swift",
                displayName: "ClaudeService.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "valid"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.displayName, "ClaudeService.swift")
    }

    func test_fromStructured_preservesModifiedStatus() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/foo.swift",
                displayName: "foo.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "modified"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.statusRaw, "modified")
    }

    func test_fromStructured_preservesMissingStatus() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/gone.swift",
                displayName: "gone.swift",
                fileKindRaw: "sourceCode",
                statusRaw: "missing"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.others.first?.statusRaw, "missing")
    }

    func test_fromStructured_imagesAndPdfsRemainsStringPaths() {
        let entries = [
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/img.png",
                displayName: "img.png",
                fileKindRaw: "image",
                statusRaw: "valid"
            ),
            AttachmentSnapshotEntry(
                id: UUID(),
                filePath: "/a/doc.pdf",
                displayName: "doc.pdf",
                fileKindRaw: "pdf",
                statusRaw: "valid"
            )
        ]
        let snapshot = MessageAttachmentSnapshot.fromStructured(entries)
        XCTAssertEqual(snapshot.images, ["/a/img.png"])
        XCTAssertEqual(snapshot.pdfs, ["/a/doc.pdf"])
        XCTAssertTrue(snapshot.others.isEmpty)
    }

    // MARK: - ParsedUserMessageText.replacingAttachments preserves metadata

    func test_replacingAttachments_preservesDisplayNameInOthers() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(),
            filePath: "/workspace/ClaudeService.swift",
            displayName: "ClaudeService.swift",
            fileKindRaw: "sourceCode",
            statusRaw: "modified"
        )
        let base = ParsedUserMessageText(
            bodyText: "hello",
            directiveAuditItems: [],
            inlineSegments: [],
            images: [],
            pdfs: [],
            others: []
        )
        let updated = base.replacingAttachments(with: [entry])
        XCTAssertEqual(updated.others.first?.displayName, "ClaudeService.swift")
        XCTAssertEqual(updated.others.first?.statusRaw, "modified")
    }

    // MARK: - FileReferencePillView label text logic

    func test_pillLabelText_withoutLineRange() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift")
    }

    func test_pillLabelText_withLineRange() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 10, lineEnd: 20
        )
        XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift:10-20")
    }

    func test_pillLabelText_singleLine() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/foo.swift", displayName: "foo.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 42, lineEnd: 42
        )
        XCTAssertEqual(FileReferencePillViewModel.labelText(for: entry), "foo.swift:42")
    }

    // MARK: - openAttachment logic

    func test_openAttachment_skipsNonexistentFile() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(),
            filePath: "/nonexistent/path/foo.swift",
            displayName: "foo.swift",
            fileKindRaw: "sourceCode",
            statusRaw: "missing"
        )
        let url = URL(fileURLWithPath: entry.filePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
