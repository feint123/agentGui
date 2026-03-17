import Foundation

struct BlockEditorUndoSnapshot: Equatable {
    var document: BlockDocument
    var presentation: BlockEditorPresentationSnapshot
    var serializedText: String?
}

struct BlockEditorPresentationSnapshot: Equatable {
    var activeBlockID: UUID?
    var focus: BlockEditorFocusSnapshot?
    var selection: BlockEditorSelectionSnapshot?
}

struct BlockEditorFocusSnapshot: Equatable {
    var blockID: UUID
    var caretUTF16Offset: Int
}

struct BlockEditorSelectionSnapshot: Equatable {
    var blockID: UUID
    var range: NSRange
}

struct BlockEditorHistoryEntry: Equatable, Identifiable {
    enum Kind: Equatable {
        case textInput(blockID: UUID)
        case blockStructure
        case inlineFormat(blockID: UUID)
        case slashCommand(blockID: UUID)
        case resourceInsert
        case externalReload
    }

    enum MergePolicy: Equatable {
        case never
        case bySession(key: String, timeout: TimeInterval)
    }

    var id: UUID
    var kind: Kind
    var title: String
    var before: BlockEditorUndoSnapshot
    var after: BlockEditorUndoSnapshot
    var mergePolicy: MergePolicy
    var timestamp: Date
}

struct BlockEditorRuntimeState: Equatable {
    var document: BlockDocument
    var fileURL: URL?
    var activeBlockID: UUID?
    var focus: BlockEditorFocusSnapshot?
    var selection: BlockEditorSelectionSnapshot?

    func snapshot(serializedText: String? = nil) -> BlockEditorUndoSnapshot {
        BlockEditorUndoSnapshot(
            document: document,
            presentation: BlockEditorPresentationSnapshot(
                activeBlockID: activeBlockID,
                focus: focus,
                selection: selection
            ),
            serializedText: serializedText ?? BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        )
    }

    mutating func apply(snapshot: BlockEditorUndoSnapshot) {
        document = snapshot.document
        activeBlockID = snapshot.presentation.activeBlockID
        focus = snapshot.presentation.focus
        selection = snapshot.presentation.selection
    }
}