import Foundation

struct BlockEditorResidency: Equatable {
    private(set) var mountedEditorIDs: [UUID] = []
    let maxMountedEditors: Int

    init(maxMountedEditors: Int = 3) {
        self.maxMountedEditors = max(1, maxMountedEditors)
    }

    mutating func recordInteraction(with blockID: UUID) {
        mountedEditorIDs.removeAll { $0 == blockID }
        mountedEditorIDs.insert(blockID, at: 0)
        if mountedEditorIDs.count > maxMountedEditors {
            mountedEditorIDs.removeSubrange(maxMountedEditors...)
        }
    }

    mutating func remove(_ blockID: UUID) {
        mountedEditorIDs.removeAll { $0 == blockID }
    }

    mutating func retain(_ validBlockIDs: some Collection<UUID>) {
        let valid = Set(validBlockIDs)
        mountedEditorIDs.removeAll { !valid.contains($0) }
    }

    func shouldMountEditor(for blockID: UUID) -> Bool {
        mountedEditorIDs.contains(blockID)
    }
}