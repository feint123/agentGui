import Foundation
import Testing
@testable import agentGui

@MainActor
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

    @Test func workspaceSummaryAggregatesCountsAndRecentDiagnostics() throws {
        let store = LSPDiagnosticsStore()
        store.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: "/repo",
                uri: "file:///repo/src/app.ts",
                diagnostics: [
                    .init(message: "Type mismatch", severity: .error),
                    .init(message: "Unused value", severity: .warning)
                ],
                updatedAt: Date(timeIntervalSince1970: 1_000)
            )
        )
        store.publish(
            LSPDiagnosticsSnapshot(
                workspaceRoot: "/repo",
                uri: "file:///repo/src/view.tsx",
                diagnostics: [
                    .init(message: "Prefer const", severity: .warning),
                    .init(message: "Hint", severity: .hint)
                ],
                updatedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        let summary = try #require(store.workspaceSummary(for: "/repo"))

        #expect(summary.filesWithDiagnostics == 2)
        #expect(summary.errorCount == 1)
        #expect(summary.warningCount == 2)
        #expect(summary.hintCount == 1)
        #expect(summary.updatedAt == Date(timeIntervalSince1970: 2_000))
        #expect(summary.recentDiagnostics.map(\.message) == ["Prefer const", "Hint", "Type mismatch", "Unused value"])
    }

    @Test func publishFromDetachedTaskMarshalsBackToMainActor() async throws {
        let store = LSPDiagnosticsStore()
        let snapshot = LSPDiagnosticsSnapshot(
            workspaceRoot: "/repo",
            uri: "file:///repo/src/app.ts",
            diagnostics: [.init(message: "Detached", severity: .warning)]
        )

        let deliveredOnMainActor = LockedBox<Bool?>(nil)
        store.onDidPublish = { received in
            deliveredOnMainActor.value = Thread.isMainThread
            #expect(received == snapshot)
        }

        let publishTask = Task.detached {
            await store.publish(snapshot)
        }

        _ = await publishTask.result
        for _ in 0..<20 where deliveredOnMainActor.value == nil {
            await Task.yield()
        }

        #expect(deliveredOnMainActor.value == true)
        #expect(store.snapshot(for: "/repo", uri: "file:///repo/src/app.ts") == snapshot)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}