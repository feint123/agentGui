import Foundation
import Testing
@testable import agentGui

struct BlockEditorResidencyTests {

    @Test func residencyKeepsMostRecentBlocksWarm() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()

        var residency = BlockEditorResidency(maxMountedEditors: 3)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)
        residency.recordInteraction(with: third)
        residency.recordInteraction(with: fourth)

        #expect(residency.mountedEditorIDs == [fourth, third, second])
        #expect(residency.shouldMountEditor(for: fourth))
        #expect(!residency.shouldMountEditor(for: first))
    }

    @Test func residencyMovesRevisitedBlockToFrontWithoutDuplicates() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        var residency = BlockEditorResidency(maxMountedEditors: 3)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)
        residency.recordInteraction(with: third)
        residency.recordInteraction(with: first)

        #expect(residency.mountedEditorIDs == [first, third, second])
    }

    @Test func residencyRemovesDeletedBlockFromMountedSet() {
        let first = UUID()
        let second = UUID()

        var residency = BlockEditorResidency(maxMountedEditors: 2)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)

        residency.remove(first)

        #expect(residency.mountedEditorIDs == [second])
        #expect(!residency.shouldMountEditor(for: first))
    }
}