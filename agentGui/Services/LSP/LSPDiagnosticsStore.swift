import Foundation

final class LSPDiagnosticsStore {
    var onDidPublish: ((LSPDiagnosticsSnapshot) -> Void)?

    private var snapshotsByKey: [SnapshotKey: LSPDiagnosticsSnapshot] = [:]

    func publish(_ snapshot: LSPDiagnosticsSnapshot) {
        snapshotsByKey[SnapshotKey(workspaceRoot: snapshot.workspaceRoot, uri: snapshot.uri)] = snapshot
        onDidPublish?(snapshot)
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

    func workspaceSummary(for workspaceRoot: String) -> LSPProjectDiagnosticsSummary? {
        let snapshots = snapshots(in: workspaceRoot)
        guard !snapshots.isEmpty else { return nil }

        let diagnostics = snapshots.flatMap { snapshot in
            snapshot.diagnostics.map {
                LSPProjectDiagnosticsSummary.DiagnosticItem(
                    uri: snapshot.uri,
                    message: $0.message,
                    severity: $0.severity,
                    source: $0.source,
                    line: $0.line,
                    character: $0.character
                )
            }
        }

        let updatedAt = snapshots.map(\.updatedAt).max() ?? .distantPast
        return LSPProjectDiagnosticsSummary(
            workspaceRoot: workspaceRoot,
            filesWithDiagnostics: snapshots.filter { !$0.diagnostics.isEmpty }.count,
            errorCount: diagnostics.filter { $0.severity == .error }.count,
            warningCount: diagnostics.filter { $0.severity == .warning }.count,
            informationCount: diagnostics.filter { $0.severity == .information }.count,
            hintCount: diagnostics.filter { $0.severity == .hint }.count,
            updatedAt: updatedAt,
            recentDiagnostics: snapshots
                .sorted {
                    if $0.updatedAt == $1.updatedAt {
                        return $0.uri < $1.uri
                    }
                    return $0.updatedAt > $1.updatedAt
                }
                .flatMap { snapshot in
                    snapshot.diagnostics.map {
                        LSPProjectDiagnosticsSummary.DiagnosticItem(
                            uri: snapshot.uri,
                            message: $0.message,
                            severity: $0.severity,
                            source: $0.source,
                            line: $0.line,
                            character: $0.character
                        )
                    }
                }
        )
    }

    private struct SnapshotKey: Hashable {
        let workspaceRoot: String
        let uri: String
    }
}