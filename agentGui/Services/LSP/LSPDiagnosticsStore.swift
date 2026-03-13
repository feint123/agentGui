import Foundation

final class LSPDiagnosticsStore {
    private var snapshotsByKey: [SnapshotKey: LSPDiagnosticsSnapshot] = [:]

    func publish(_ snapshot: LSPDiagnosticsSnapshot) {
        snapshotsByKey[SnapshotKey(workspaceRoot: snapshot.workspaceRoot, uri: snapshot.uri)] = snapshot
    }

    func snapshot(for workspaceRoot: String, uri: String) -> LSPDiagnosticsSnapshot? {
        snapshotsByKey[SnapshotKey(workspaceRoot: workspaceRoot, uri: uri)]
    }

    func snapshots(in workspaceRoot: String) -> [LSPDiagnosticsSnapshot] {
        snapshotsByKey
            .filter { $0.key.workspaceRoot == workspaceRoot }
            .map(\.value)
            .sorted { $0.uri < $1.uri }
    }

    private struct SnapshotKey: Hashable {
        let workspaceRoot: String
        let uri: String
    }
}