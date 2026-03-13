import Foundation
import Testing
@testable import agentGui

struct LSPDiagnosticsStoreTests {

    @Test func publishStoresDiagnosticsForWorkspaceAndURI() {
        let store = LSPDiagnosticsStore()
        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/repo",
            uri: "file:///repo/src/app.ts",
            diagnostics: [
                .init(message: "Missing semicolon", severity: .warning)
            ]
        )

        store.publish(snapshot)

        #expect(store.snapshot(for: "/repo", uri: "file:///repo/src/app.ts") == snapshot)
    }

    @Test func publishOverwritesExistingSnapshotForSameWorkspaceAndURI() {
        let store = LSPDiagnosticsStore()
        store.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: "/repo",
                uri: "file:///repo/src/app.ts",
                diagnostics: [.init(message: "Old", severity: .warning)]
            )
        )

        let updated = LSPDiagnosticsSnapshot(
            workspaceRoot: "/repo",
            uri: "file:///repo/src/app.ts",
            diagnostics: [.init(message: "New", severity: .error)]
        )
        store.publish(updated)

        #expect(store.snapshot(for: "/repo", uri: "file:///repo/src/app.ts") == updated)
    }

    @Test func snapshotsInWorkspaceReturnsOnlyMatchingWorkspaceEntries() {
        let store = LSPDiagnosticsStore()
        store.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: "/repo-a",
                uri: "file:///repo-a/src/a.ts",
                diagnostics: [.init(message: "A", severity: .warning)]
            )
        )
        store.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: "/repo-b",
                uri: "file:///repo-b/src/b.ts",
                diagnostics: [.init(message: "B", severity: .warning)]
            )
        )

        let snapshots = store.snapshots(in: "/repo-a")

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.uri == "file:///repo-a/src/a.ts")
    }
}