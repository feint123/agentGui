import CoreGraphics
import Foundation

enum BlockEditorLayoutCoordinateSpace {
    static let canvas = "BlockEditorCanvas"
}

enum BlockEditorBlockSelectionSource: Equatable {
    case click
    case commandClick
    case shiftClick
    case marquee
    case keyboard
    case contextMenu
}

struct BlockEditorMarqueeSelection: Equatable {
    var startPoint: CGPoint
    var currentPoint: CGPoint
    var isAdditive: Bool

    var rect: CGRect {
        CGRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }
}

struct BlockEditorBlockSelectionState: Equatable {
    var selectedBlockIDs: Set<UUID>
    var primaryBlockID: UUID?
    var anchorBlockID: UUID?
    var source: BlockEditorBlockSelectionSource
    var marqueeSelection: BlockEditorMarqueeSelection?

    static let empty = BlockEditorBlockSelectionState(
        selectedBlockIDs: [],
        primaryBlockID: nil,
        anchorBlockID: nil,
        source: .click,
        marqueeSelection: nil
    )

    static func single(_ blockID: UUID, source: BlockEditorBlockSelectionSource = .click) -> BlockEditorBlockSelectionState {
        BlockEditorBlockSelectionState(
            selectedBlockIDs: [blockID],
            primaryBlockID: blockID,
            anchorBlockID: blockID,
            source: source,
            marqueeSelection: nil
        )
    }

    var hasSelection: Bool {
        !selectedBlockIDs.isEmpty
    }
}
