import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct BlockDocumentEditorUndoTests {

    @Test func continuousTypingCoalescesIntoSingleUndoStep() {
        let harness = BlockDocumentTypingUndoHarness(initialText: "")

        harness.typeText("h")
        harness.typeText("e")
        harness.typeText("l")
        harness.typeText("l")
        harness.typeText("o")

        #expect(harness.undoStepCount == 1)

        harness.undo()
        #expect(harness.currentText == "")
    }

    @Test func textViewRoutesUndoAndRedoCommands() {
        let textView = BlockEditorTextView()
        var receivedUndo = false
        var receivedRedo = false

        textView.onCommand = { command in
            switch command {
            case .undo:
                receivedUndo = true
            case .redo:
                receivedRedo = true
            default:
                break
            }
        }

        textView.doCommand(by: Selector(("undo:")))
        textView.doCommand(by: Selector(("redo:")))

        #expect(receivedUndo)
        #expect(receivedRedo)
    }

    @Test func textViewRoutesUndoAndRedoActionsFromResponderChain() {
        let textView = BlockEditorTextView()
        var receivedUndo = false
        var receivedRedo = false

        textView.onCommand = { command in
            switch command {
            case .undo:
                receivedUndo = true
            case .redo:
                receivedRedo = true
            default:
                break
            }
        }

        _ = textView.tryToPerform(Selector(("undo:")), with: nil)
        _ = textView.tryToPerform(Selector(("redo:")), with: nil)

        #expect(receivedUndo)
        #expect(receivedRedo)
    }

    @Test func commandResponderRoutesUndoAndRedoWithoutTextViewFocus() {
        let responderView = BlockEditorCommandResponderView()
        var receivedUndo = false
        var receivedRedo = false

        responderView.onUndo = { receivedUndo = true }
        responderView.onRedo = { receivedRedo = true }

        _ = responderView.tryToPerform(Selector(("undo:")), with: nil)
        _ = responderView.tryToPerform(Selector(("redo:")), with: nil)

        #expect(receivedUndo)
        #expect(receivedRedo)
    }

    @Test func deleteBlockCanUndoAndRestorePreviousDocumentShape() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["hello", "world"])

        let targetID = harness.runtime.document.blocks[1].id
        harness.deleteBlock(id: targetID)
        #expect(harness.blockCount == 1)
        #expect(harness.runtime.focus?.blockID == harness.runtime.document.blocks[0].id)
        #expect(harness.runtime.focus?.caretUTF16Offset == harness.runtime.document.blocks[0].text.utf16.count)

        harness.undo()
        #expect(harness.blockCount == 2)
        #expect(harness.texts == ["hello", "world"])

        harness.redo()
        #expect(harness.blockCount == 1)
    }

    @Test func blockSelectionStateParticipatesInUndoSnapshots() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["hello", "world"])
        let selectedID = harness.runtime.document.blocks[1].id

        harness.selectBlocks([selectedID])
        harness.deleteSelectedBlocks()
        #expect(harness.runtime.blockSelection.selectedBlockIDs.count == 1)

        harness.undo()
        #expect(harness.runtime.document.blocks.count == 2)
        #expect(harness.runtime.blockSelection.selectedBlockIDs == Set([selectedID]))
    }

    @Test func splitBlockCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["hello world"])
        let blockID = harness.runtime.document.blocks[0].id

        harness.splitBlock(id: blockID, location: 5)
        #expect(harness.texts == ["hello", " world"])

        harness.undo()
        #expect(harness.texts == ["hello world"])

        harness.redo()
        #expect(harness.texts == ["hello", " world"])
    }

    @Test func mergeBlockBackwardCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["hello", "world"])
        let secondID = harness.runtime.document.blocks[1].id

        harness.mergeBlockBackward(id: secondID)
        #expect(harness.texts == ["hello world"])

        harness.undo()
        #expect(harness.texts == ["hello", "world"])
    }

    @Test func convertBlockCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["hello"])
        let blockID = harness.runtime.document.blocks[0].id

        harness.convertBlock(id: blockID, to: .heading1)
        #expect(harness.runtime.document.blocks[0].kind == .heading1)

        harness.undo()
        #expect(harness.runtime.document.blocks[0].kind == .paragraph)
    }

    @Test func adjustIndentationCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(blocks: [DocumentBlock(kind: .bulletedList, text: "item")])
        let blockID = harness.runtime.document.blocks[0].id

        harness.adjustIndentation(for: blockID, delta: 1)
        #expect(harness.runtime.document.blocks[0].metadata.indentLevel == 1)

        harness.undo()
        #expect(harness.runtime.document.blocks[0].metadata.indentLevel == 0)
    }

    @Test func clearFormattingCanUndoAndRedo() {
        var todo = DocumentBlock.empty(.todo)
        todo.text = "/clear done"
        todo.metadata.checked = true
        let harness = BlockDocumentEditorUndoHarness(blocks: [todo])
        let blockID = harness.runtime.document.blocks[0].id

        harness.clearFormatting(for: blockID, tokenRange: NSRange(location: 0, length: 6))
        #expect(harness.runtime.document.blocks[0].kind == .paragraph)
        #expect(harness.runtime.document.blocks[0].text == "done")

        harness.undo()
        #expect(harness.runtime.document.blocks[0].kind == .todo)
        #expect(harness.runtime.document.blocks[0].metadata.checked)
    }

    @Test func createTablePresetCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["/table"])
        let blockID = harness.runtime.document.blocks[0].id

        harness.createTablePreset(rows: 2, columns: 2, for: blockID, tokenRange: NSRange(location: 0, length: 6))
        #expect(harness.runtime.document.blocks[0].kind == .table)
        #expect(harness.runtime.document.blocks[0].text.contains("列 1"))

        harness.undo()
        #expect(harness.runtime.document.blocks[0].kind == .paragraph)
        #expect(harness.runtime.document.blocks[0].text == "/table")
    }

    @Test func reorderBlocksCanUndoAndRedo() {
        let harness = BlockDocumentEditorUndoHarness(texts: ["one", "two", "three"])

        harness.reorderBlock(from: 0, to: 2)
        #expect(harness.texts == ["two", "one", "three"])

        harness.undo()
        #expect(harness.texts == ["one", "two", "three"])

        harness.redo()
        #expect(harness.texts == ["two", "one", "three"])
    }

    @Test func toggleMetadataEditsCanUndoAndRedo() {
        var toggle = DocumentBlock.empty(.toggle)
        toggle.text = "details"
        toggle.metadata.secondaryText = "before"
        toggle.metadata.isCollapsed = false
        let harness = BlockDocumentEditorUndoHarness(blocks: [toggle])
        let blockID = harness.runtime.document.blocks[0].id

        harness.updateToggleMetadata(id: blockID, title: "after", isCollapsed: true)
        #expect(harness.runtime.document.blocks[0].metadata.secondaryText == "after")
        #expect(harness.runtime.document.blocks[0].metadata.isCollapsed)

        harness.undo()
        #expect(harness.runtime.document.blocks[0].metadata.secondaryText == "before")
        #expect(!harness.runtime.document.blocks[0].metadata.isCollapsed)
    }

    @Test func calloutMetadataEditsCanUndoAndRedo() {
        var callout = DocumentBlock.empty(.callout)
        callout.text = "body"
        callout.metadata.tone = "note"
        callout.metadata.secondaryText = "before"
        let harness = BlockDocumentEditorUndoHarness(blocks: [callout])
        let blockID = harness.runtime.document.blocks[0].id

        harness.updateCalloutMetadata(id: blockID, tone: "warning", title: "after")
        #expect(harness.runtime.document.blocks[0].metadata.tone == "warning")
        #expect(harness.runtime.document.blocks[0].metadata.secondaryText == "after")

        harness.undo()
        #expect(harness.runtime.document.blocks[0].metadata.tone == "note")
        #expect(harness.runtime.document.blocks[0].metadata.secondaryText == "before")
    }
}

private final class BlockDocumentEditorUndoHarness {
    var runtime: BlockEditorRuntimeState
    var driver = BlockEditorMutationDriver(history: BlockEditorHistoryController())

    init(texts: [String]) {
        self.runtime = Self.makeRuntime(from: texts.map { DocumentBlock(kind: .paragraph, text: $0) })
    }

    init(blocks: [DocumentBlock]) {
        self.runtime = Self.makeRuntime(from: blocks)
    }

    var blockCount: Int { runtime.document.blocks.count }
    var texts: [String] { runtime.document.blocks.map(\.text) }

    func convertBlock(id: UUID, to kind: DocumentBlockKind) {
        driver.applyMutation(kind: .blockStructure, title: "Convert", editor: &runtime) { runtime in
            runtime.convertBlock(id: id, to: kind)
        }
    }

    func splitBlock(id: UUID, location: Int) {
        driver.applyMutation(kind: .blockStructure, title: "Split", editor: &runtime) { runtime in
            runtime.splitBlock(id: id, selectedRange: NSRange(location: location, length: 0))
        }
    }

    func mergeBlockBackward(id: UUID) {
        driver.applyMutation(kind: .blockStructure, title: "Merge", editor: &runtime) { runtime in
            runtime.mergeBlockBackward(id: id)
        }
    }

    func deleteBlock(id: UUID) {
        driver.applyMutation(kind: .blockStructure, title: "Delete", editor: &runtime) { runtime in
            runtime.deleteBlock(id: id)
        }
    }

    func selectBlocks(_ ids: Set<UUID>) {
        runtime.blockSelection = BlockEditorBlockSelectionState(
            selectedBlockIDs: ids,
            primaryBlockID: ids.first,
            anchorBlockID: ids.first,
            source: .click,
            marqueeSelection: nil
        )
    }

    func deleteSelectedBlocks() {
        driver.applyMutation(kind: .blockStructure, title: "Delete Selected", editor: &runtime) { runtime in
            BlockEditorSelectionMutationHandler.deleteSelectedBlocks(in: &runtime)
        }
    }

    func adjustIndentation(for id: UUID, delta: Int) {
        driver.applyMutation(kind: .blockStructure, title: "Indent", editor: &runtime) { runtime in
            runtime.adjustIndentation(for: id, delta: delta)
        }
    }

    func clearFormatting(for id: UUID, tokenRange: NSRange) {
        driver.applyMutation(kind: .blockStructure, title: "Clear", editor: &runtime) { runtime in
            runtime.clearFormatting(for: id, tokenRange: tokenRange)
        }
    }

    func createTablePreset(rows: Int, columns: Int, for id: UUID, tokenRange: NSRange) {
        driver.applyMutation(kind: .blockStructure, title: "Table", editor: &runtime) { runtime in
            runtime.createTablePreset(rows: rows, columns: columns, for: id, tokenRange: tokenRange)
        }
    }

    func reorderBlock(from sourceIndex: Int, to destinationIndex: Int) {
        driver.applyMutation(kind: .blockStructure, title: "Reorder", editor: &runtime) { runtime in
            runtime.reorderBlock(from: sourceIndex, to: destinationIndex)
        }
    }

    func updateToggleMetadata(id: UUID, title: String, isCollapsed: Bool) {
        driver.applyMutation(kind: .blockStructure, title: "Toggle Metadata", editor: &runtime) { runtime in
            runtime.updateToggleMetadata(id: id, title: title, isCollapsed: isCollapsed)
        }
    }

    func updateCalloutMetadata(id: UUID, tone: String, title: String) {
        driver.applyMutation(kind: .blockStructure, title: "Callout Metadata", editor: &runtime) { runtime in
            runtime.updateCalloutMetadata(id: id, tone: tone, title: title)
        }
    }

    func undo() {
        guard let snapshot = driver.history.undo(current: runtime.snapshot()) else { return }
        runtime.apply(snapshot: snapshot)
    }

    func redo() {
        guard let snapshot = driver.history.redo(current: runtime.snapshot()) else { return }
        runtime.apply(snapshot: snapshot)
    }

    private static func makeRuntime(from blocks: [DocumentBlock]) -> BlockEditorRuntimeState {
        let preparedBlocks = blocks.isEmpty ? [.empty(.paragraph)] : blocks
        return BlockEditorRuntimeState(
            document: BlockDocument(blocks: preparedBlocks),
            fileURL: nil,
            activeBlockID: preparedBlocks.first?.id,
            focus: nil,
            selection: nil,
            blockSelection: .empty
        )
    }
}

private final class BlockDocumentTypingUndoHarness {
    var runtime: BlockEditorRuntimeState
    var history = BlockEditorHistoryController()
    var session: BlockEditorTextEditSession?

    init(initialText: String) {
        let block = DocumentBlock(kind: .paragraph, text: initialText)
        runtime = BlockEditorRuntimeState(
            document: BlockDocument(blocks: [block]),
            fileURL: nil,
            activeBlockID: block.id,
            focus: nil,
            selection: nil,
            blockSelection: .empty
        )
    }

    var currentText: String {
        runtime.document.blocks[0].text
    }

    var undoStepCount: Int {
        history.past.count + (session == nil ? 0 : 1)
    }

    func typeText(_ chunk: String, at timestamp: Date = Date()) {
        let previousRuntime = runtime
        runtime.document.blocks[0].text += chunk
        let latestSnapshot = runtime.snapshot()

        if var session, session.canCoalesce(with: runtime.document.blocks[0].id, at: timestamp, timeout: 1.0) {
            session.latest = latestSnapshot
            session.lastEditedAt = timestamp
            self.session = session
        } else {
            flushTypingSession()
            session = BlockEditorTextEditSession(
                blockID: runtime.document.blocks[0].id,
                baseline: previousRuntime.snapshot(),
                latest: latestSnapshot,
                startedAt: timestamp,
                lastEditedAt: timestamp
            )
        }
    }

    func undo() {
        flushTypingSession()
        guard let snapshot = history.undo(current: runtime.snapshot()) else { return }
        runtime.apply(snapshot: snapshot)
    }

    private func flushTypingSession() {
        guard let session else { return }
        defer { self.session = nil }
        guard session.baseline != session.latest else { return }
        history.record(
            BlockEditorHistoryEntry(
                id: UUID(),
                kind: .textInput(blockID: session.blockID),
                title: "Typing",
                before: session.baseline,
                after: session.latest,
                mergePolicy: .never,
                timestamp: session.lastEditedAt
            )
        )
    }
}