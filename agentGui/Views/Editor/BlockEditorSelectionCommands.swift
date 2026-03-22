import Foundation

enum BlockEditorSelectionExportFormat: String, Equatable {
    case markdown
    case plainText
    case html
}

enum BlockEditorSelectionCommand: Equatable {
    case cut
    case copy
    case copyAs(BlockEditorSelectionExportFormat)
    case duplicate
    case delete
    case selectAll
    case clearSelection
}

struct BlockEditorSelectionCommandResult: Equatable {
    var payload: BlockEditorSelectionSerializedPayload?
    var runtime: BlockEditorRuntimeState
}

enum BlockEditorSelectionMutationHandler {
    static func deleteSelectedBlocks(in runtime: inout BlockEditorRuntimeState) {
        let orderedBlockIDs = runtime.document.blocks.map(\.id)
        let selectedIDs = orderedBlockIDs.filter { runtime.blockSelection.selectedBlockIDs.contains($0) }
        guard !selectedIDs.isEmpty else { return }

        let removedIndexSet = IndexSet(
            runtime.document.blocks.enumerated().compactMap { index, block in
                runtime.blockSelection.selectedBlockIDs.contains(block.id) ? index : nil
            }
        )
        let fallbackIndex = max((removedIndexSet.first ?? 0) - 1, 0)

        runtime.document.blocks.removeAll { runtime.blockSelection.selectedBlockIDs.contains($0.id) }
        if runtime.document.blocks.isEmpty {
            let placeholder = DocumentBlock.empty(.paragraph)
            runtime.document.blocks = [placeholder]
            runtime.activeBlockID = placeholder.id
            runtime.focus = nil
            runtime.selection = nil
            runtime.blockSelection = .single(placeholder.id, source: .keyboard)
            return
        }

        let safeFallbackIndex = min(fallbackIndex, runtime.document.blocks.count - 1)
        let fallbackID = runtime.document.blocks[safeFallbackIndex].id
        runtime.activeBlockID = fallbackID
        runtime.focus = nil
        runtime.selection = nil
        runtime.blockSelection = .single(fallbackID, source: .keyboard)
    }

    static func duplicateSelectedBlocks(in runtime: inout BlockEditorRuntimeState) {
        let orderedSelectedIDs = runtime.document.blocks
            .map(\.id)
            .filter { runtime.blockSelection.selectedBlockIDs.contains($0) }
        guard !orderedSelectedIDs.isEmpty else { return }

        var duplicatedIDs: [UUID] = []
        var duplicatedBlocks: [DocumentBlock] = []
        duplicatedBlocks.reserveCapacity(runtime.document.blocks.count + orderedSelectedIDs.count)

        for block in runtime.document.blocks {
            duplicatedBlocks.append(block)
            guard runtime.blockSelection.selectedBlockIDs.contains(block.id) else { continue }
            var copy = block
            copy.id = UUID()
            duplicatedBlocks.append(copy)
            duplicatedIDs.append(copy.id)
        }

        runtime.document.blocks = duplicatedBlocks
        runtime.activeBlockID = duplicatedIDs.last
        runtime.focus = nil
        runtime.selection = nil
        runtime.blockSelection = BlockEditorBlockSelectionState(
            selectedBlockIDs: Set(duplicatedIDs),
            primaryBlockID: duplicatedIDs.last,
            anchorBlockID: duplicatedIDs.first,
            source: .contextMenu,
            marqueeSelection: nil
        )
    }
}

enum BlockEditorSelectionCommandRouter {
    static func execute(
        command: BlockEditorSelectionCommand,
        runtime: inout BlockEditorRuntimeState,
        fileURL: URL?
    ) -> BlockEditorSelectionCommandResult {
        switch command {
        case .copy:
            return BlockEditorSelectionCommandResult(
                payload: payload(for: runtime, fileURL: fileURL),
                runtime: runtime
            )

        case .copyAs:
            return BlockEditorSelectionCommandResult(
                payload: payload(for: runtime, fileURL: fileURL),
                runtime: runtime
            )

        case .cut:
            let copiedPayload = payload(for: runtime, fileURL: fileURL)
            BlockEditorSelectionMutationHandler.deleteSelectedBlocks(in: &runtime)
            return BlockEditorSelectionCommandResult(payload: copiedPayload, runtime: runtime)

        case .duplicate:
            BlockEditorSelectionMutationHandler.duplicateSelectedBlocks(in: &runtime)
            return BlockEditorSelectionCommandResult(payload: nil, runtime: runtime)

        case .delete:
            BlockEditorSelectionMutationHandler.deleteSelectedBlocks(in: &runtime)
            return BlockEditorSelectionCommandResult(payload: nil, runtime: runtime)

        case .selectAll:
            let orderedBlockIDs = runtime.document.blocks.map(\.id)
            runtime.blockSelection = BlockEditorBlockSelectionState(
                selectedBlockIDs: Set(orderedBlockIDs),
                primaryBlockID: orderedBlockIDs.last,
                anchorBlockID: orderedBlockIDs.first,
                source: .keyboard,
                marqueeSelection: nil
            )
            runtime.activeBlockID = runtime.blockSelection.primaryBlockID
            runtime.focus = nil
            runtime.selection = nil
            return BlockEditorSelectionCommandResult(payload: nil, runtime: runtime)

        case .clearSelection:
            runtime.blockSelection = .empty
            return BlockEditorSelectionCommandResult(payload: nil, runtime: runtime)
        }
    }

    static func selectedBlocks(in runtime: BlockEditorRuntimeState) -> [DocumentBlock] {
        runtime.document.blocks.filter { runtime.blockSelection.selectedBlockIDs.contains($0.id) }
    }

    private static func payload(for runtime: BlockEditorRuntimeState, fileURL: URL?) -> BlockEditorSelectionSerializedPayload? {
        let blocks = selectedBlocks(in: runtime)
        guard !blocks.isEmpty else { return nil }
        return BlockEditorSelectionSerializer.serialize(blocks: blocks, fileURL: fileURL)
    }
}