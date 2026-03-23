import CoreGraphics
import Foundation
import Testing
@testable import agentGui

@MainActor
struct BlockEditorBlockSelectionCoordinatorTests {

    @Test func singleSelectionKeepsOnlyTargetBlock() {
        let ids = [UUID(), UUID(), UUID()]

        let result = BlockEditorBlockSelectionCoordinator.selectSingle(
            targetBlockID: ids[1],
            source: .click
        )

        #expect(result.selectedBlockIDs == [ids[1]])
        #expect(result.primaryBlockID == ids[1])
        #expect(result.anchorBlockID == ids[1])
        #expect(result.source == .click)
    }

    @Test func commandToggleAddsAndRemovesTargetBlock() {
        let ids = [UUID(), UUID(), UUID()]
        let state = BlockEditorBlockSelectionState(
            selectedBlockIDs: [ids[0]],
            primaryBlockID: ids[0],
            anchorBlockID: ids[0],
            source: .click,
            marqueeSelection: nil
        )

        let added = BlockEditorBlockSelectionCoordinator.toggleSelection(
            state: state,
            targetBlockID: ids[2],
            source: .commandClick
        )

        #expect(added.selectedBlockIDs == [ids[0], ids[2]])
        #expect(added.primaryBlockID == ids[2])
        #expect(added.anchorBlockID == ids[0])

        let removed = BlockEditorBlockSelectionCoordinator.toggleSelection(
            state: added,
            targetBlockID: ids[2],
            source: .commandClick
        )

        #expect(removed.selectedBlockIDs == [ids[0]])
        #expect(removed.primaryBlockID == ids[0])
        #expect(removed.anchorBlockID == ids[0])
    }

    @Test func shiftSelectionBuildsContiguousRangeFromAnchor() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        var state = BlockEditorBlockSelectionState.single(ids[1])
        state.anchorBlockID = ids[1]

        let result = BlockEditorBlockSelectionCoordinator.extendRange(
            state: state,
            orderedBlockIDs: ids,
            targetBlockID: ids[3],
            source: .shiftClick
        )

        #expect(result.selectedBlockIDs == Set([ids[1], ids[2], ids[3]]))
        #expect(result.primaryBlockID == ids[3])
        #expect(result.anchorBlockID == ids[1])
        #expect(result.source == .shiftClick)
    }

    @Test func remapSelectionPrunesDeletedBlocksAndPromotesNearestExistingSelection() {
        let ids = [UUID(), UUID(), UUID()]
        let state = BlockEditorBlockSelectionState(
            selectedBlockIDs: [ids[0], ids[1]],
            primaryBlockID: ids[1],
            anchorBlockID: ids[0],
            source: .commandClick,
            marqueeSelection: nil
        )

        let result = BlockEditorBlockSelectionCoordinator.remapSelection(
            state: state,
            orderedBlockIDs: [ids[2], ids[0]]
        )

        #expect(result.selectedBlockIDs == [ids[0]])
        #expect(result.primaryBlockID == ids[0])
        #expect(result.anchorBlockID == ids[0])
    }

    @Test func marqueeHitTestingReturnsBlocksIntersectingSelectionRectInDocumentOrder() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let blockFrames: [UUID: CGRect] = [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40),
            ids[2]: CGRect(x: 0, y: 100, width: 100, height: 40),
            ids[3]: CGRect(x: 0, y: 150, width: 100, height: 40)
        ]

        let marquee = BlockEditorMarqueeSelection(
            startPoint: CGPoint(x: 4, y: 48),
            currentPoint: CGPoint(x: 80, y: 145),
            isAdditive: false
        )

        let result = BlockEditorBlockSelectionCoordinator.selectionFromMarquee(
            state: .empty,
            orderedBlockIDs: ids,
            blockFrames: blockFrames,
            marquee: marquee,
            source: .marquee
        )

        #expect(result.selectedBlockIDs == Set([ids[1], ids[2]]))
        #expect(result.primaryBlockID == ids[2])
        #expect(result.anchorBlockID == ids[1])
        #expect(result.marqueeSelection == marquee)
    }

    @Test func additiveMarqueeUnionsWithExistingSelection() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let blockFrames: [UUID: CGRect] = [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40),
            ids[2]: CGRect(x: 0, y: 100, width: 100, height: 40),
            ids[3]: CGRect(x: 0, y: 150, width: 100, height: 40)
        ]
        let state = BlockEditorBlockSelectionState.single(ids[0])
        let marquee = BlockEditorMarqueeSelection(
            startPoint: CGPoint(x: 4, y: 98),
            currentPoint: CGPoint(x: 80, y: 195),
            isAdditive: true
        )

        let result = BlockEditorBlockSelectionCoordinator.selectionFromMarquee(
            state: state,
            orderedBlockIDs: ids,
            blockFrames: blockFrames,
            marquee: marquee,
            source: .marquee
        )

        #expect(result.selectedBlockIDs == Set([ids[0], ids[2], ids[3]]))
        #expect(result.primaryBlockID == ids[3])
        #expect(result.anchorBlockID == ids[0])
    }

    @Test func marqueeWithoutAnyMeasuredFramesProducesEmptySelection() {
        let ids = [UUID(), UUID()]
        let marquee = BlockEditorMarqueeSelection(
            startPoint: CGPoint(x: 0, y: 0),
            currentPoint: CGPoint(x: 100, y: 100),
            isAdditive: false
        )

        let result = BlockEditorBlockSelectionCoordinator.selectionFromMarquee(
            state: .single(ids[0]),
            orderedBlockIDs: ids,
            blockFrames: [:],
            marquee: marquee,
            source: .marquee
        )

        #expect(result.selectedBlockIDs.isEmpty)
        #expect(result.primaryBlockID == nil)
        #expect(result.anchorBlockID == nil)
        #expect(result.marqueeSelection == marquee)
    }
}