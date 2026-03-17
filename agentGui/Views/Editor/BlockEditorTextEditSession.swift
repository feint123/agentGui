import Foundation

struct BlockEditorTextEditSession: Equatable {
    let blockID: UUID
    let baseline: BlockEditorUndoSnapshot
    var latest: BlockEditorUndoSnapshot
    let startedAt: Date
    var lastEditedAt: Date

    func canCoalesce(with blockID: UUID, at timestamp: Date, timeout: TimeInterval) -> Bool {
        self.blockID == blockID && timestamp.timeIntervalSince(lastEditedAt) <= timeout
    }
}