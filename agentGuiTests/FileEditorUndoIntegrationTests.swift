import Foundation
import Testing
@testable import agentGui

@MainActor
struct FileEditorUndoIntegrationTests {

    @Test func saveMarksCleanAnchorWithoutClearingUndoHistory() async throws {
        let harness = try await FileEditorUndoHarness.openTextFile("hello")
        defer { harness.cleanup() }

        harness.typeText("hello world")
        try await harness.save()

        #expect(harness.hasUndoHistory)
        #expect(!harness.hasUnsavedChanges)

        harness.undo()
        #expect(harness.hasUnsavedChanges)
        #expect(harness.currentText == "hello")
    }

    @Test func reloadFromDiskResetsHistoryAndDirtyState() async throws {
        let harness = try await FileEditorUndoHarness.openTextFile("hello")
        defer { harness.cleanup() }

        harness.typeText("hello world")
        #expect(harness.hasUnsavedChanges)

        try await harness.reloadFromDisk("external")

        #expect(!harness.hasUndoHistory)
        #expect(!harness.hasUnsavedChanges)
        #expect(harness.currentText == "external")
    }
}

@MainActor
private final class FileEditorUndoHarness {
    let controller: FileEditorSessionController
    let fileURL: URL
    private(set) var history = BlockEditorHistoryController()

    static func openTextFile(_ contents: String) async throws -> FileEditorUndoHarness {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-file-editor-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("note.md")
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let harness = FileEditorUndoHarness(fileURL: fileURL)
        await harness.controller.open(fileURL)
        harness.history.markClean(at: harness.snapshot(for: harness.controller.document.textContent))
        return harness
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.controller = FileEditorSessionController()
    }

    var currentText: String {
        controller.document.textContent
    }

    var hasUndoHistory: Bool {
        !history.past.isEmpty
    }

    var hasUnsavedChanges: Bool {
        controller.document.hasUnsavedChanges
    }

    func typeText(_ newText: String) {
        let before = snapshot(for: controller.document.textContent)
        controller.updateText(newText)
        let after = snapshot(for: controller.document.textContent)
        history.record(
            BlockEditorHistoryEntry(
                id: UUID(),
                kind: .textInput(blockID: after.presentation.activeBlockID ?? UUID()),
                title: "Typing",
                before: before,
                after: after,
                mergePolicy: .never,
                timestamp: Date()
            )
        )
    }

    func save() async throws {
        await controller.save()
        history.markClean(at: snapshot(for: controller.document.textContent))
    }

    func undo() {
        guard let restored = history.undo(current: snapshot(for: controller.document.textContent)),
              let text = restored.serializedText else {
            return
        }
        controller.updateText(text)
    }

    func reloadFromDisk(_ contents: String) async throws {
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        await controller.open(fileURL)
        history.reset()
        history.markClean(at: snapshot(for: controller.document.textContent))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func snapshot(for text: String) -> BlockEditorUndoSnapshot {
        let document = BlockMarkdownCodec.parse(text, fileURL: fileURL)
        let activeBlockID = document.blocks.first?.id
        return BlockEditorUndoSnapshot(
            document: document,
            presentation: BlockEditorPresentationSnapshot(
                activeBlockID: activeBlockID,
                focus: nil,
                selection: nil
            ),
            serializedText: text
        )
    }
}