import Foundation
import Testing
@testable import agentGui

struct WorkspaceChangeCaptureServiceTests {

    @Test func collectArtifactsBuildsDiffsFromRealWorkspaceSnapshots() throws {
        let harness = try WorkspaceChangeCaptureHarness.make()
        let service = WorkspaceChangeCaptureService(fileManager: .default)
        let snapshot = try service.captureSnapshot(root: harness.workspaceRoot)

        try "edited".write(to: harness.workspaceRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: harness.workspaceRoot.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: harness.workspaceRoot.appending(path: "delete.txt"))

        let artifacts = try service.collectArtifacts(from: snapshot)
        #expect(artifacts.map(\.relativePath) == ["delete.txt", "file.txt", "new.txt"])

        let deleted = try #require(artifacts.first(where: { $0.relativePath == "delete.txt" }))
        #expect(deleted.changeKind == .delete)
        #expect(deleted.baseContentSnapshot == "remove me")
        #expect(deleted.stagedContentSnapshot == nil)

        let modified = try #require(artifacts.first(where: { $0.relativePath == "file.txt" }))
        #expect(modified.changeKind == .modify)
        #expect(modified.baseContentSnapshot == "original")
        #expect(modified.stagedContentSnapshot == "edited")
        #expect(modified.unifiedDiff.contains("+edited"))

        let added = try #require(artifacts.first(where: { $0.relativePath == "new.txt" }))
        #expect(added.changeKind == .add)
        #expect(added.baseContentSnapshot == nil)
        #expect(added.stagedContentSnapshot == "new")
        #expect(added.unifiedDiff.contains("+new"))
    }

    @Test func captureSnapshotSkipsBinaryFilesAndStillTracksTextChanges() throws {
        let harness = try WorkspaceChangeCaptureHarness.make()
        let service = WorkspaceChangeCaptureService(fileManager: .default)
        let binaryURL = harness.workspaceRoot.appending(path: "image.bin")
        try Data([0xFF, 0xD8, 0xFF, 0x00]).write(to: binaryURL)

        let snapshot = try service.captureSnapshot(root: harness.workspaceRoot)

        #expect(snapshot.filesByRelativePath["image.bin"] == nil)

        try "edited".write(to: harness.workspaceRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)

        let artifacts = try service.collectArtifacts(from: snapshot)
        #expect(artifacts.map(\.relativePath) == ["file.txt"])
        #expect(artifacts.first?.stagedContentSnapshot == "edited")
    }

    @Test @MainActor func detachedExecutorRunsSnapshotAndDiffOffMainThread() async throws {
        let rootURL = URL(fileURLWithPath: "/tmp/agentgui-workspace-capture-off-main")
        let recorder = MainThreadRecorder()
        let expectedSnapshot = WorkspaceTextSnapshot(root: rootURL, filesByRelativePath: [:])
        let executor = DetachedWorkspaceChangeCaptureExecutor(
            captureSnapshotOperation: { root in
                recorder.record(key: "snapshot", value: Thread.isMainThread)
                return WorkspaceTextSnapshot(root: root, filesByRelativePath: [:])
            },
            collectArtifactsOperation: { snapshot in
                recorder.record(key: "artifacts", value: Thread.isMainThread)
                return snapshot.filesByRelativePath.isEmpty ? [] : []
            }
        )

        let snapshot = try await executor.captureSnapshot(root: expectedSnapshot.root)
        let artifacts = try await executor.collectArtifacts(from: snapshot)

        #expect(snapshot.root == expectedSnapshot.root)
        #expect(artifacts.isEmpty)
        #expect(recorder.value(for: "snapshot") == false)
        #expect(recorder.value(for: "artifacts") == false)
    }

    @Test func detachedExecutorPropagatesCancellationToBackgroundTask() async throws {
        let executor = DetachedWorkspaceChangeCaptureExecutor(
            captureSnapshotOperation: { root in
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                _ = root
                throw CancellationError()
            },
            collectArtifactsOperation: { _ in [] }
        )

        let task = Task {
            try await executor.captureSnapshot(root: URL(fileURLWithPath: "/tmp/agentgui-workspace-capture-cancel"))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private struct WorkspaceChangeCaptureHarness {
    let workspaceRoot: URL

    static func make() throws -> Self {
        let workspaceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try "original".write(to: workspaceRoot.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try "remove me".write(to: workspaceRoot.appending(path: "delete.txt"), atomically: true, encoding: .utf8)
        return Self(workspaceRoot: workspaceRoot)
    }
}

private final class MainThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func record(key: String, value: Bool) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func value(for key: String) -> Bool? {
        lock.lock()
        let value = values[key]
        lock.unlock()
        return value
    }
}