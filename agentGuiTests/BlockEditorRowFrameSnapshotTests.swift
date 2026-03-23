import CoreGraphics
import Foundation
import Testing
@testable import agentGui

struct BlockEditorRowFrameSnapshotTests {

    @Test func snapshotsWithSameFramesCompareEqual() {
        let ids = [UUID(), UUID()]
        let lhs = BlockEditorRowFrameSnapshot(frames: [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40)
        ])
        let rhs = BlockEditorRowFrameSnapshot(frames: [
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40),
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40)
        ])

        #expect(lhs == rhs)
    }

    @Test func tinyGeometryJitterWithinToleranceComparesEqual() {
        let id = UUID()
        let baseline = BlockEditorRowFrameSnapshot(frames: [
            id: CGRect(x: 10, y: 20, width: 200, height: 44)
        ])
        let jittered = BlockEditorRowFrameSnapshot(frames: [
            id: CGRect(x: 10.2, y: 20.2, width: 200.1, height: 44.1)
        ])

        #expect(baseline == jittered)
    }

    @Test func materiallyChangedGeometryDoesNotCompareEqual() {
        let id = UUID()
        let baseline = BlockEditorRowFrameSnapshot(frames: [
            id: CGRect(x: 10, y: 20, width: 200, height: 44)
        ])
        let moved = BlockEditorRowFrameSnapshot(frames: [
            id: CGRect(x: 24, y: 20, width: 200, height: 44)
        ])

        #expect(baseline != moved)
    }

    @Test func pruningRemovesFramesForDeletedBlocks() {
        let ids = [UUID(), UUID(), UUID()]
        let snapshot = BlockEditorRowFrameSnapshot(frames: [
            ids[0]: CGRect(x: 0, y: 0, width: 100, height: 40),
            ids[1]: CGRect(x: 0, y: 50, width: 100, height: 40),
            ids[2]: CGRect(x: 0, y: 100, width: 100, height: 40)
        ])

        let pruned = snapshot.pruned(to: [ids[0], ids[2]])

        #expect(pruned.frame(for: ids[0]) != nil)
        #expect(pruned.frame(for: ids[1]) == nil)
        #expect(pruned.frame(for: ids[2]) != nil)
    }
}