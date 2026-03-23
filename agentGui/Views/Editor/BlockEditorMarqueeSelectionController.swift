import Foundation

struct BlockEditorMarqueeSelectionResult: Equatable {
    let state: BlockEditorBlockSelectionState
    let shouldMutateState: Bool
    let shouldSyncRuntimeSelection: Bool
    let shouldUpdateActiveBlock: Bool
}

struct BlockEditorMarqueeSelectionController {
    func reduce(
        baseState: BlockEditorBlockSelectionState,
        currentState: BlockEditorBlockSelectionState,
        orderedBlockIDs: [UUID],
        rowFrames: BlockEditorRowFrameSnapshot,
        marquee: BlockEditorMarqueeSelection
    ) -> BlockEditorMarqueeSelectionResult {
        let nextState = BlockEditorBlockSelectionCoordinator.selectionFromMarquee(
            state: baseState,
            orderedBlockIDs: orderedBlockIDs,
            blockFrames: rowFrames.frames,
            marquee: marquee,
            source: .marquee
        )

        let shouldMutateState = currentState.selectionIdentity != nextState.selectionIdentity
        let shouldUpdateActiveBlock = currentState.primaryBlockID != nextState.primaryBlockID

        return BlockEditorMarqueeSelectionResult(
            state: nextState,
            shouldMutateState: shouldMutateState,
            shouldSyncRuntimeSelection: shouldMutateState,
            shouldUpdateActiveBlock: shouldUpdateActiveBlock
        )
    }
}

private extension BlockEditorBlockSelectionState {
    var selectionIdentity: SelectionIdentity {
        SelectionIdentity(
            selectedBlockIDs: selectedBlockIDs,
            primaryBlockID: primaryBlockID,
            anchorBlockID: anchorBlockID,
            source: source
        )
    }
}

private struct SelectionIdentity: Equatable {
    let selectedBlockIDs: Set<UUID>
    let primaryBlockID: UUID?
    let anchorBlockID: UUID?
    let source: BlockEditorBlockSelectionSource
}