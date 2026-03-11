import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeRefreshCoordinatorTests {

    @Test func latestDirectoryLoadWinsWhenEarlierScanFinishesLate() async throws {
        let observationFactory = RecordingWorkspaceDirectoryObservationFactory()
        let firstDirectory = URL(fileURLWithPath: "/tmp/workspace/first")
        let secondDirectory = URL(fileURLWithPath: "/tmp/workspace/second")
        let delayedBuilder = DelayedTreeBuilder()
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: observationFactory.makeFactory(),
            debounceNanoseconds: 5_000_000,
            buildNodes: delayedBuilder.build,
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )

        var observedRoots: [[URL]] = []
        coordinator.onNodesChanged = { nodes, _ in
            observedRoots.append(nodes.map(\.id))
        }

        coordinator.setDirectory(firstDirectory)
        coordinator.setDirectory(secondDirectory)

        await delayedBuilder.resume(directory: secondDirectory, nodes: [FileNode(id: secondDirectory.appending(path: "fresh.swift"), name: "fresh.swift", isDirectory: false, children: nil)])
        try await Task.sleep(nanoseconds: 50_000_000)
        await delayedBuilder.resume(directory: firstDirectory, nodes: [FileNode(id: firstDirectory.appending(path: "stale.swift"), name: "stale.swift", isDirectory: false, children: nil)])
        try await Task.sleep(nanoseconds: 50_000_000)

        let finalRoots = try #require(observedRoots.last)
        #expect(finalRoots == [secondDirectory.appending(path: "fresh.swift")])
    }

    @Test func debouncesMultipleDirectoryEventsIntoSingleRefresh() async throws {
        let observationFactory = RecordingWorkspaceDirectoryObservationFactory()
        let root = URL(fileURLWithPath: "/tmp/workspace/root")
        let changedDirectory = root.appending(path: "Sources")
        let changedFile = changedDirectory.appending(path: "App.swift")
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: observationFactory.makeFactory(),
            debounceNanoseconds: 20_000_000,
            buildNodes: { _ in [FileNode(id: changedDirectory, name: "Sources", isDirectory: true, children: [])] },
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )

        let initialLoad = AsyncSignal()
        var settledRefreshCount = 0
        coordinator.onNodesChanged = { _, loading in
            if !loading {
                settledRefreshCount += 1
                Task {
                    await initialLoad.fire()
                }
            }
        }
        coordinator.setDirectory(root)
        await initialLoad.wait()

        let observation = try #require(observationFactory.observations.first)
        observation.emit(paths: [changedFile.path])
        observation.emit(paths: [changedDirectory.path])

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(settledRefreshCount == 2)
    }

    @Test func clearingDirectoryStopsObservationAndPreventsFurtherUpdates() async throws {
        let observationFactory = RecordingWorkspaceDirectoryObservationFactory()
        let root = URL(fileURLWithPath: "/tmp/workspace/root")
        let coordinator = WorkspaceTreeRefreshCoordinator(
            observationFactory: observationFactory.makeFactory(),
            debounceNanoseconds: 10_000_000,
            buildNodes: { _ in [] },
            shallowScan: { _ in [] },
            mergeNodes: { existing, _ in existing },
            applyPartialUpdate: { nodes, _ in nodes }
        )

        var updateCount = 0
        coordinator.onNodesChanged = { _, _ in updateCount += 1 }

        coordinator.setDirectory(root)
        try await Task.sleep(nanoseconds: 50_000_000)
        let observation = try #require(observationFactory.observations.first)

        coordinator.setDirectory(nil)
        observation.emit(paths: [root.appending(path: "ghost.swift").path])
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(observation.stopCallCount == 1)
        #expect(updateCount == 3)
    }
}

private actor DelayedTreeBuilder {
    private var continuations: [URL: CheckedContinuation<[FileNode], Never>] = [:]
    private var pendingResults: [URL: [FileNode]] = [:]

    func build(_ url: URL) async -> [FileNode] {
        let standardizedURL = url.standardizedFileURL
        if let pending = pendingResults.removeValue(forKey: standardizedURL) {
            return pending
        }
        return await withCheckedContinuation { continuation in
            continuations[standardizedURL] = continuation
        }
    }

    func resume(directory: URL, nodes: [FileNode]) {
        let standardizedURL = directory.standardizedFileURL
        if let continuation = continuations.removeValue(forKey: standardizedURL) {
            continuation.resume(returning: nodes)
        } else {
            pendingResults[standardizedURL] = nodes
        }
    }
}

private actor AsyncSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hasFired = false

    func wait() async {
        if hasFired { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func fire() {
        guard !hasFired else { return }
        hasFired = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class RecordingWorkspaceDirectoryObservationFactory {
    private(set) var startedURLs: [URL] = []
    private(set) var observations: [RecordingWorkspaceDirectoryObservation] = []

    func makeFactory() -> WorkspaceDirectoryObservationFactory {
        WorkspaceDirectoryObservationFactory { url, onChange in
            self.startedURLs.append(url)
            let observation = RecordingWorkspaceDirectoryObservation(url: url, onChange: onChange)
            self.observations.append(observation)
            return observation
        }
    }
}

private final class RecordingWorkspaceDirectoryObservation: WorkspaceDirectoryObservationSession {
    let url: URL
    private let onChange: ([String]) -> Void
    private(set) var stopCallCount = 0

    init(url: URL, onChange: @escaping ([String]) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func stop() {
        stopCallCount += 1
    }

    func emit(paths: [String]) {
        onChange(paths)
    }
}