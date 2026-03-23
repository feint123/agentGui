import CoreGraphics
import Foundation
import Testing
@testable import agentGui

struct BlockEditorMarqueeSelectionControllerTests {

    @Test func firstMeaningfulMarqueeHitRequestsSelectionMutation() {
        let ids = [UUID(), UUID()]
        let controller = BlockEditorMarqueeSelectionController()
        let snapshot = BlockEditorRowFrameSnapshot(frames: [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40)
        ])

        let result = controller.reduce(
            baseState: .empty,
            currentState: .empty,
            orderedBlockIDs: ids,
            rowFrames: snapshot,
            marquee: BlockEditorMarqueeSelection(
                startPoint: CGPoint(x: 0, y: 0),
                currentPoint: CGPoint(x: 80, y: 60),
                isAdditive: false
            )
        )

        #expect(result.shouldMutateState)
        #expect(result.shouldSyncRuntimeSelection)
        #expect(result.shouldUpdateActiveBlock)
        #expect(result.state.selectedBlockIDs == Set([ids[0], ids[1]]))
    }

    @Test func marqueeMoveThatDoesNotChangeHitSetDoesNotRequestStateMutation() {
        let ids = [UUID(), UUID()]
        let controller = BlockEditorMarqueeSelectionController()
        let snapshot = BlockEditorRowFrameSnapshot(frames: [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40)
        ])

        let first = controller.reduce(
            baseState: .empty,
            currentState: .empty,
            orderedBlockIDs: ids,
            rowFrames: snapshot,
            marquee: BlockEditorMarqueeSelection(
                startPoint: CGPoint(x: 0, y: 0),
                currentPoint: CGPoint(x: 80, y: 60),
                isAdditive: false
            )
        )

        let second = controller.reduce(
            baseState: .empty,
            currentState: first.state,
            orderedBlockIDs: ids,
            rowFrames: snapshot,
            marquee: BlockEditorMarqueeSelection(
                startPoint: CGPoint(x: 0, y: 0),
                currentPoint: CGPoint(x: 81, y: 61),
                isAdditive: false
            )
        )

        #expect(second.shouldMutateState == false)
        #expect(second.shouldSyncRuntimeSelection == false)
        #expect(second.shouldUpdateActiveBlock == false)
    }

    @Test func additiveMarqueeKeepsExistingPrimaryWhenHitSetDoesNotAdvance() {
        let ids = [UUID(), UUID(), UUID()]
        let controller = BlockEditorMarqueeSelectionController()
        let baseState = BlockEditorBlockSelectionState.single(ids[0])
        let snapshot = BlockEditorRowFrameSnapshot(frames: [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40),
            ids[2]: CGRect(x: 0, y: 100, width: 100, height: 40)
        ])

        let result = controller.reduce(
            baseState: baseState,
            currentState: baseState,
            orderedBlockIDs: ids,
            rowFrames: snapshot,
            marquee: BlockEditorMarqueeSelection(
                startPoint: CGPoint(x: 0, y: 0),
                currentPoint: CGPoint(x: 80, y: 45),
                isAdditive: true
            )
        )

        #expect(result.state.primaryBlockID == ids[0])
        #expect(result.state.selectedBlockIDs == Set([ids[0]]))
        #expect(result.shouldUpdateActiveBlock == false)
    }
}