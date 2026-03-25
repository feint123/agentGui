import Foundation

@MainActor
final class WorkbenchContextWindowRouter {
    typealias OpenWindowWithValue = @MainActor (_ id: String, _ value: WorkbenchContextSceneValue) -> Void

    private let diffSnapshotStore: WorkbenchDiffSnapshotStore
    private let openWindowWithValue: OpenWindowWithValue

    init(
        diffSnapshotStore: WorkbenchDiffSnapshotStore = .shared,
        openWindowWithValue: @escaping OpenWindowWithValue
    ) {
        self.diffSnapshotStore = diffSnapshotStore
        self.openWindowWithValue = openWindowWithValue
    }

    func open(selection: WorkbenchDetailSelection) {
        guard let value = WorkbenchContextSceneValue(
            selection: selection,
            diffSnapshotStore: diffSnapshotStore
        ) else {
            return
        }

        openWindowWithValue(WorkbenchContextWindowScene.id, value)
    }
}