import CoreGraphics
import Foundation

struct BlockEditorRowFrameSnapshot: Equatable {
    static let empty = BlockEditorRowFrameSnapshot(frames: [:])

    let frames: [UUID: CGRect]

    private let tolerance: CGFloat

    init(frames: [UUID: CGRect], tolerance: CGFloat = 0.5) {
        self.tolerance = tolerance
        self.frames = frames.mapValues { Self.normalize($0, tolerance: tolerance) }
    }

    var isEmpty: Bool {
        frames.isEmpty
    }

    func frame(for blockID: UUID) -> CGRect? {
        frames[blockID]
    }

    func pruned(to validIDs: some Sequence<UUID>) -> BlockEditorRowFrameSnapshot {
        let validIDSet = Set(validIDs)
        let filteredFrames = frames.filter { validIDSet.contains($0.key) }
        return BlockEditorRowFrameSnapshot(frames: filteredFrames, tolerance: tolerance)
    }

    private static func normalize(_ rect: CGRect, tolerance: CGFloat) -> CGRect {
        guard tolerance > 0 else { return rect.integral }
        return CGRect(
            x: normalize(rect.origin.x, tolerance: tolerance),
            y: normalize(rect.origin.y, tolerance: tolerance),
            width: normalize(rect.size.width, tolerance: tolerance),
            height: normalize(rect.size.height, tolerance: tolerance)
        )
    }

    private static func normalize(_ value: CGFloat, tolerance: CGFloat) -> CGFloat {
        (value / tolerance).rounded() * tolerance
    }
}