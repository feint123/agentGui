import Foundation

struct BlockEditorHistoryController {
    private(set) var past: [BlockEditorHistoryEntry] = []
    private(set) var future: [BlockEditorHistoryEntry] = []

    private var cleanPastCount = 0

    var isAtCleanRevision: Bool {
        past.count == cleanPastCount
    }

    mutating func record(_ entry: BlockEditorHistoryEntry) {
        future.removeAll()

        if let last = past.last,
           shouldMerge(last: last, next: entry) {
            past[past.count - 1].after = entry.after
            past[past.count - 1].timestamp = entry.timestamp
            return
        }

        past.append(entry)
    }

    mutating func undo(current: BlockEditorUndoSnapshot) -> BlockEditorUndoSnapshot? {
        guard let entry = past.popLast() else { return nil }
        future.append(entry)
        return entry.before
    }

    mutating func redo(current: BlockEditorUndoSnapshot) -> BlockEditorUndoSnapshot? {
        guard let entry = future.popLast() else { return nil }
        past.append(entry)
        return entry.after
    }

    mutating func markClean(at snapshot: BlockEditorUndoSnapshot) {
        cleanPastCount = past.count
    }

    mutating func reset() {
        past.removeAll()
        future.removeAll()
        cleanPastCount = 0
    }

    private func shouldMerge(last: BlockEditorHistoryEntry, next: BlockEditorHistoryEntry) -> Bool {
        switch (last.mergePolicy, next.mergePolicy) {
        case (.bySession(let lastKey, let timeout), .bySession(let nextKey, _)):
            guard lastKey == nextKey else { return false }
            return next.timestamp.timeIntervalSince(last.timestamp) <= timeout
        default:
            return false
        }
    }
}