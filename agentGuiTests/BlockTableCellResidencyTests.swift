import Foundation
import Testing
@testable import agentGui

struct BlockTableCellResidencyTests {

    @Test func residencyKeepsMostRecentCellsWarm() {
        let first = BlockTableCellID(row: 0, column: 0)
        let second = BlockTableCellID(row: 0, column: 1)
        let third = BlockTableCellID(row: 1, column: 0)

        var residency = BlockTableCellResidency(maxMountedEditors: 2)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)
        residency.recordInteraction(with: third)

        #expect(residency.mountedCellIDs == [third, second])
        #expect(residency.shouldMountEditor(for: third))
        #expect(!residency.shouldMountEditor(for: first))
    }

    @Test func residencyMovesRevisitedCellToFrontWithoutDuplicates() {
        let first = BlockTableCellID(row: 0, column: 0)
        let second = BlockTableCellID(row: 0, column: 1)

        var residency = BlockTableCellResidency(maxMountedEditors: 2)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)
        residency.recordInteraction(with: first)

        #expect(residency.mountedCellIDs == [first, second])
    }

    @Test func residencyDropsCellsThatNoLongerExist() {
        let first = BlockTableCellID(row: 0, column: 0)
        let second = BlockTableCellID(row: 1, column: 1)

        var residency = BlockTableCellResidency(maxMountedEditors: 2)
        residency.recordInteraction(with: first)
        residency.recordInteraction(with: second)

        residency.retain(in: [["A"]])

        #expect(residency.mountedCellIDs == [first])
        #expect(!residency.shouldMountEditor(for: second))
    }
}