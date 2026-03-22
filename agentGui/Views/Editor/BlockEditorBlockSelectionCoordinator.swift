import CoreGraphics
import Foundation

enum BlockEditorBlockSelectionCoordinator {
    static func selectSingle(
        targetBlockID: UUID,
        source: BlockEditorBlockSelectionSource
    ) -> BlockEditorBlockSelectionState {
        .single(targetBlockID, source: source)
    }

    static func toggleSelection(
        state: BlockEditorBlockSelectionState,
        targetBlockID: UUID,
        source: BlockEditorBlockSelectionSource
    ) -> BlockEditorBlockSelectionState {
        var selectedBlockIDs = state.selectedBlockIDs
        if selectedBlockIDs.contains(targetBlockID) {
            selectedBlockIDs.remove(targetBlockID)
        } else {
            selectedBlockIDs.insert(targetBlockID)
        }

        let primaryBlockID: UUID?
        if selectedBlockIDs.contains(targetBlockID) {
            primaryBlockID = targetBlockID
        } else {
            primaryBlockID = state.anchorBlockID ?? selectedBlockIDs.first
        }

        let anchorBlockID = state.anchorBlockID ?? primaryBlockID

        return BlockEditorBlockSelectionState(
            selectedBlockIDs: selectedBlockIDs,
            primaryBlockID: primaryBlockID,
            anchorBlockID: anchorBlockID,
            source: source,
            marqueeSelection: nil
        )
    }

    static func extendRange(
        state: BlockEditorBlockSelectionState,
        orderedBlockIDs: [UUID],
        targetBlockID: UUID,
        source: BlockEditorBlockSelectionSource
    ) -> BlockEditorBlockSelectionState {
        let anchorBlockID = state.anchorBlockID ?? state.primaryBlockID ?? targetBlockID
        guard let anchorIndex = orderedBlockIDs.firstIndex(of: anchorBlockID),
              let targetIndex = orderedBlockIDs.firstIndex(of: targetBlockID) else {
            return .single(targetBlockID, source: source)
        }

        let lowerBound = min(anchorIndex, targetIndex)
        let upperBound = max(anchorIndex, targetIndex)
        let selectedBlockIDs = Set(orderedBlockIDs[lowerBound...upperBound])

        return BlockEditorBlockSelectionState(
            selectedBlockIDs: selectedBlockIDs,
            primaryBlockID: targetBlockID,
            anchorBlockID: anchorBlockID,
            source: source,
            marqueeSelection: nil
        )
    }

    static func remapSelection(
        state: BlockEditorBlockSelectionState,
        orderedBlockIDs: [UUID]
    ) -> BlockEditorBlockSelectionState {
        let validIDs = Set(orderedBlockIDs)
        let surviving = state.selectedBlockIDs.filter { validIDs.contains($0) }
        guard !surviving.isEmpty else {
            return .empty
        }

        let primaryBlockID = validatedPreferredID(
            preferredID: state.primaryBlockID,
            fallbackIDs: surviving,
            orderedBlockIDs: orderedBlockIDs
        )
        let anchorBlockID = validatedPreferredID(
            preferredID: state.anchorBlockID,
            fallbackIDs: surviving,
            orderedBlockIDs: orderedBlockIDs
        ) ?? primaryBlockID

        return BlockEditorBlockSelectionState(
            selectedBlockIDs: Set(surviving),
            primaryBlockID: primaryBlockID,
            anchorBlockID: anchorBlockID,
            source: state.source,
            marqueeSelection: nil
        )
    }

    static func selectionFromMarquee(
        state: BlockEditorBlockSelectionState,
        orderedBlockIDs: [UUID],
        blockFrames: [UUID: CGRect],
        marquee: BlockEditorMarqueeSelection,
        source: BlockEditorBlockSelectionSource
    ) -> BlockEditorBlockSelectionState {
        let hitIDs = orderedBlockIDs.filter { blockID in
            guard let frame = blockFrames[blockID] else { return false }
            return frame.intersects(marquee.rect)
        }

        let selectedBlockIDs: Set<UUID>
        let anchorBlockID: UUID?
        if marquee.isAdditive {
            selectedBlockIDs = state.selectedBlockIDs.union(hitIDs)
            anchorBlockID = state.anchorBlockID ?? state.primaryBlockID ?? hitIDs.first
        } else {
            selectedBlockIDs = Set(hitIDs)
            anchorBlockID = hitIDs.first
        }

        let primaryBlockID = hitIDs.last ?? (marquee.isAdditive ? state.primaryBlockID : nil)

        return BlockEditorBlockSelectionState(
            selectedBlockIDs: selectedBlockIDs,
            primaryBlockID: primaryBlockID,
            anchorBlockID: anchorBlockID,
            source: source,
            marqueeSelection: marquee
        )
    }

    private static func validatedPreferredID(
        preferredID: UUID?,
        fallbackIDs: some Sequence<UUID>,
        orderedBlockIDs: [UUID]
    ) -> UUID? {
        if let preferredID,
           orderedBlockIDs.contains(preferredID) {
            return preferredID
        }

        let fallbackSet = Set(fallbackIDs)
        return orderedBlockIDs.first(where: { fallbackSet.contains($0) })
    }
}