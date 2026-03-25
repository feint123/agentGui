import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchContextWindowRouterTests {

    @Test func openFileSelectionEmitsFileSceneValue() {
        let recorder = ContextWindowRouteRecorder()
        let router = WorkbenchContextWindowRouter(
            diffSnapshotStore: .inMemory,
            openWindowWithValue: recorder.openWindow
        )

        router.open(selection: .file(URL(fileURLWithPath: "/tmp/repo/file.swift")))

        #expect(recorder.windowIDs == [WorkbenchContextWindowScene.id])
        #expect(recorder.values == [.file(path: "/tmp/repo/file.swift")])
    }

    @Test func openDiffSelectionStoresSnapshotBackedSceneValue() {
        let recorder = ContextWindowRouteRecorder()
        let store = WorkbenchDiffSnapshotStore.inMemory
        let router = WorkbenchContextWindowRouter(
            diffSnapshotStore: store,
            openWindowWithValue: recorder.openWindow
        )

        router.open(selection: .gitDiff(title: "A.swift", diffText: "diff --git a/A.swift b/A.swift"))

        #expect(recorder.windowIDs == [WorkbenchContextWindowScene.id])

        guard case .gitDiff(let title, let snapshotID) = recorder.values.first else {
            Issue.record("Expected gitDiff scene value")
            return
        }

        #expect(title == "A.swift")
        #expect(store.snapshot(for: snapshotID)?.diffText == "diff --git a/A.swift b/A.swift")
    }

    @Test func openNoneSelectionDoesNothing() {
        let recorder = ContextWindowRouteRecorder()
        let router = WorkbenchContextWindowRouter(
            diffSnapshotStore: .inMemory,
            openWindowWithValue: recorder.openWindow
        )

        router.open(selection: .none)

        #expect(recorder.windowIDs.isEmpty)
        #expect(recorder.values.isEmpty)
    }
}

@MainActor
private final class ContextWindowRouteRecorder {
    private(set) var windowIDs: [String] = []
    private(set) var values: [WorkbenchContextSceneValue] = []

    func openWindow(_ id: String, _ value: WorkbenchContextSceneValue) {
        windowIDs.append(id)
        values.append(value)
    }
}