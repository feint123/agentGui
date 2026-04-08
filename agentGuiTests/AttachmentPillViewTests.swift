import XCTest
@testable import agentGui

final class AttachmentPillViewTests: XCTestCase {

    // MARK: - AttachmentPillViewModel helpers

    func test_isMediaEntry_image() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/photo.png", displayName: "photo.png",
            fileKindRaw: "image", statusRaw: "valid"
        )
        XCTAssertTrue(AttachmentPillViewModel.isMedia(entry))
    }

    func test_isMediaEntry_pdf() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/doc.pdf", displayName: "doc.pdf",
            fileKindRaw: "pdf", statusRaw: "valid"
        )
        XCTAssertTrue(AttachmentPillViewModel.isMedia(entry))
    }

    func test_isMediaEntry_sourceCode() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertFalse(AttachmentPillViewModel.isMedia(entry))
    }

    func test_labelText_plainFile() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift")
    }

    func test_labelText_withLineRange() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 10, lineEnd: 20
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift:10-20")
    }

    func test_labelText_withSingleLine() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 42, lineEnd: 42
        )
        XCTAssertEqual(AttachmentPillViewModel.labelText(for: entry), "main.swift:42")
    }

    func test_pillIcon_sourceCode() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/main.swift", displayName: "main.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "doc.text")
    }

    func test_pillIcon_directory() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/src", displayName: "src",
            fileKindRaw: "directory", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "folder")
    }

    func test_pillIcon_image() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/photo.png", displayName: "photo.png",
            fileKindRaw: "image", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "photo")
    }

    func test_pillIcon_pdf() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/doc.pdf", displayName: "doc.pdf",
            fileKindRaw: "pdf", statusRaw: "valid"
        )
        XCTAssertEqual(AttachmentPillViewModel.iconName(for: entry), "doc.richtext")
    }

    func test_supportsPreview_project_true() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertTrue(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_focused_true() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "focused"
        )
        XCTAssertTrue(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_external_false() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "external"
        )
        XCTAssertFalse(AttachmentPillViewModel.supportsPreview(entry))
    }

    func test_supportsPreview_image_false() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/img.png", displayName: "img.png",
            fileKindRaw: "image", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertFalse(AttachmentPillViewModel.supportsPreview(entry))
    }

    // MARK: - Open behavior

    func test_openBehavior_project_isEditReveal() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .editReveal)
    }

    func test_openBehavior_focused_isEditReveal() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            originRaw: "focused"
        )
        XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .editReveal)
    }

    func test_openBehavior_external_isSystemOpen() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.txt", displayName: "f.txt",
            fileKindRaw: "other", statusRaw: "valid",
            originRaw: "external"
        )
        XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .systemOpen)
    }

    func test_openBehavior_image_isMediaViewer() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/img.png", displayName: "img.png",
            fileKindRaw: "image", statusRaw: "valid",
            originRaw: "project"
        )
        XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .mediaViewer)
    }

    func test_openBehavior_missing_isNone() {
        let entry = AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/f.swift", displayName: "f.swift",
            fileKindRaw: "sourceCode", statusRaw: "missing",
            originRaw: "project"
        )
        XCTAssertEqual(AttachmentPillViewModel.openBehavior(for: entry), .none)
    }
}
