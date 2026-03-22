import Foundation
import Testing
@testable import agentGui

struct BlockEditorHistoryControllerTests {

    @Test func recordClearsFutureHistory() {
        var history = BlockEditorHistoryController()
        let firstBefore = BlockEditorUndoSnapshot.fixture(text: "one")
        let firstAfter = BlockEditorUndoSnapshot.fixture(text: "one two")
        let secondAfter = BlockEditorUndoSnapshot.fixture(text: "one two three")

        history.record(.fixture(before: firstBefore, after: firstAfter, kind: .blockStructure))
        _ = history.undo(current: firstAfter)

        #expect(history.future.count == 1)

        history.record(.fixture(before: firstBefore, after: secondAfter, kind: .blockStructure))

        #expect(history.past.count == 1)
        #expect(history.future.isEmpty)
        #expect(history.past.last?.after == secondAfter)
    }

    @Test func undoReturnsEntryBeforeSnapshotAndMovesEntryToFuture() {
        var history = BlockEditorHistoryController()
        let before = BlockEditorUndoSnapshot.fixture(text: "hello")
        let after = BlockEditorUndoSnapshot.fixture(text: "hello world")

        history.record(.fixture(before: before, after: after, kind: .blockStructure))

        let restored = history.undo(current: after)

        #expect(restored == before)
        #expect(history.past.isEmpty)
        #expect(history.future.count == 1)
    }

    @Test func redoReturnsEntryAfterSnapshotAndMovesEntryBackToPast() {
        var history = BlockEditorHistoryController()
        let before = BlockEditorUndoSnapshot.fixture(text: "hello")
        let after = BlockEditorUndoSnapshot.fixture(text: "hello world")

        history.record(.fixture(before: before, after: after, kind: .blockStructure))
        _ = history.undo(current: after)

        let restored = history.redo(current: before)

        #expect(restored == after)
        #expect(history.past.count == 1)
        #expect(history.future.isEmpty)
    }

    @Test func mergeableEntriesReplaceLastAfterSnapshot() {
        var history = BlockEditorHistoryController()
        let before = BlockEditorUndoSnapshot.fixture(text: "h")
        let mid = BlockEditorUndoSnapshot.fixture(text: "he")
        let after = BlockEditorUndoSnapshot.fixture(text: "hel")

        history.record(.fixture(before: before, after: mid, kind: .textInput(blockID: UUID()), mergePolicy: .bySession(key: "block-1", timeout: 1.0)))
        history.record(.fixture(before: mid, after: after, kind: .textInput(blockID: UUID()), mergePolicy: .bySession(key: "block-1", timeout: 1.0)))

        #expect(history.past.count == 1)
        #expect(history.past.last?.before == before)
        #expect(history.past.last?.after == after)
    }

    @Test func markCleanTracksCleanRevision() {
        var history = BlockEditorHistoryController()
        let clean = BlockEditorUndoSnapshot.fixture(text: "hello")
        let dirty = BlockEditorUndoSnapshot.fixture(text: "hello world")

        history.markClean(at: clean)
        #expect(history.isAtCleanRevision)

        history.record(.fixture(before: clean, after: dirty, kind: .blockStructure))
        #expect(!history.isAtCleanRevision)

        _ = history.undo(current: dirty)
        #expect(history.isAtCleanRevision)
    }
}

private extension BlockEditorUndoSnapshot {
    static func fixture(
        text: String,
        activeBlockID: UUID? = nil
    ) -> BlockEditorUndoSnapshot {
        let blockID = activeBlockID ?? UUID()
        return BlockEditorUndoSnapshot(
            document: BlockDocument(blocks: [DocumentBlock(id: blockID, kind: .paragraph, text: text)]),
            presentation: BlockEditorPresentationSnapshot(
                activeBlockID: blockID,
                focus: nil,
                selection: nil,
                blockSelection: .empty
            ),
            serializedText: text
        )
    }
}

private extension BlockEditorHistoryEntry {
    static func fixture(
        before: BlockEditorUndoSnapshot,
        after: BlockEditorUndoSnapshot,
        kind: Kind,
        mergePolicy: MergePolicy = .never,
        timestamp: Date = .init()
    ) -> BlockEditorHistoryEntry {
        BlockEditorHistoryEntry(
            id: UUID(),
            kind: kind,
            title: "fixture",
            before: before,
            after: after,
            mergePolicy: mergePolicy,
            timestamp: timestamp
        )
    }
}