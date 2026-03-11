import Foundation
import CoreServices

protocol WorkspaceDirectoryObservationSession: AnyObject {
    func stop()
}

struct WorkspaceDirectoryObservationFactory {
    let makeObservation: (URL, @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession?

    init(_ makeObservation: @escaping (URL, @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession?) {
        self.makeObservation = makeObservation
    }

    func make(url: URL, onChange: @escaping ([String]) -> Void) -> WorkspaceDirectoryObservationSession? {
        makeObservation(url.standardizedFileURL, onChange)
    }

    static let live = WorkspaceDirectoryObservationFactory { url, onChange in
        LiveWorkspaceDirectoryObservation(url: url, onChange: onChange)
    }
}

typealias WorkspaceTreeShallowEntry = (name: String, url: URL, isDirectory: Bool)

@MainActor
final class WorkspaceTreeRefreshCoordinator {
    var onNodesChanged: (([FileNode], Bool) -> Void)?

    private let observationFactory: WorkspaceDirectoryObservationFactory
    private let debounceNanoseconds: UInt64
    private let buildNodesClosure: @Sendable (URL) async -> [FileNode]
    private let shallowScanClosure: @Sendable (URL) async -> [WorkspaceTreeShallowEntry]
    private let mergeNodesClosure: @Sendable ([FileNode], [WorkspaceTreeShallowEntry]) async -> [FileNode]
    private let applyPartialUpdateClosure: @Sendable ([FileNode], URL) async -> [FileNode]

    private var activeObservation: WorkspaceDirectoryObservationSession?
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var currentDirectory: URL?
    private var currentNodes: [FileNode] = []
    private var pendingPaths: Set<String> = []
    private var generation: Int = 0

    init(
        observationFactory: WorkspaceDirectoryObservationFactory = .live,
        debounceNanoseconds: UInt64 = 150_000_000,
        buildNodes: @escaping @Sendable (URL) async -> [FileNode] = { url in
            WorkspaceTreeSnapshotOps.buildNodes(at: url, depth: 0)
        },
        shallowScan: @escaping @Sendable (URL) async -> [WorkspaceTreeShallowEntry] = { url in
            WorkspaceTreeSnapshotOps.shallowScan(at: url)
        },
        mergeNodes: @escaping @Sendable ([FileNode], [WorkspaceTreeShallowEntry]) async -> [FileNode] = { existing, freshScan in
            WorkspaceTreeSnapshotOps.mergeNodes(existing: existing, freshScan: freshScan)
        },
        applyPartialUpdate: @escaping @Sendable ([FileNode], URL) async -> [FileNode] = { nodes, targetURL in
            WorkspaceTreeSnapshotOps.applyPartialUpdate(to: nodes, at: targetURL)
        }
    ) {
        self.observationFactory = observationFactory
        self.debounceNanoseconds = debounceNanoseconds
        self.buildNodesClosure = buildNodes
        self.shallowScanClosure = shallowScan
        self.mergeNodesClosure = mergeNodes
        self.applyPartialUpdateClosure = applyPartialUpdate
    }

    deinit {
        activeObservation?.stop()
        debounceTask?.cancel()
        scanTask?.cancel()
    }

    func setDirectory(_ url: URL?) {
        generation += 1
        let currentGeneration = generation

        activeObservation?.stop()
        activeObservation = nil
        debounceTask?.cancel()
        debounceTask = nil
        scanTask?.cancel()
        scanTask = nil
        pendingPaths.removeAll()

        guard let url else {
            currentDirectory = nil
            currentNodes = []
            onNodesChanged?([], false)
            return
        }

        let standardizedURL = url.standardizedFileURL
        currentDirectory = standardizedURL
        currentNodes = []
        onNodesChanged?([], true)

        activeObservation = observationFactory.make(url: standardizedURL) { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                self?.enqueue(paths: changedPaths, generation: currentGeneration)
            }
        }

        scheduleFullReload(for: standardizedURL, generation: currentGeneration)
    }

    private func enqueue(paths: [String], generation: Int) {
        guard generation == self.generation else { return }

        pendingPaths.formUnion(paths)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let drainedPaths = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            await self.refresh(paths: drainedPaths, generation: generation)
        }
    }

    private func scheduleFullReload(for url: URL, generation: Int) {
        let buildNodes = buildNodesClosure
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let nodes = await buildNodes(url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation, self.currentDirectory == url else { return }
                self.currentNodes = nodes
                self.onNodesChanged?(nodes, false)
            }
        }
    }

    private func refresh(paths: [String], generation: Int) async {
        guard generation == self.generation, let rootURL = currentDirectory else { return }

        let refreshTargets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: rootURL)
        guard !refreshTargets.isEmpty else { return }

        let snapshot = currentNodes
        guard !snapshot.isEmpty else {
            scheduleFullReload(for: rootURL, generation: generation)
            return
        }

        let shallowScan = shallowScanClosure
        let mergeNodes = mergeNodesClosure
        let applyPartialUpdate = applyPartialUpdateClosure

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var updated = snapshot
            for targetURL in refreshTargets {
                guard !Task.isCancelled else { return }
                if targetURL == rootURL {
                    let freshScan = await shallowScan(rootURL)
                    updated = await mergeNodes(updated, freshScan)
                } else {
                    updated = await applyPartialUpdate(updated, targetURL)
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation, self.currentDirectory == rootURL else { return }
                self.currentNodes = updated
                self.onNodesChanged?(updated, false)
            }
        }
    }
}

enum WorkspaceTreeSnapshotOps {
    private static let scanResourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]

    static func refreshTargets(for paths: [String], rootURL: URL) -> [URL] {
        let rootStandardizedURL = rootURL.standardizedFileURL
        let rootPath = rootStandardizedURL.path
        var dirtyDirectories = Set<URL>()

        for path in paths {
            let changedURL = URL(fileURLWithPath: path).standardizedFileURL
            let parentURL = changedURL.deletingLastPathComponent()

            if parentURL.path == rootPath || parentURL.path.hasPrefix(rootPath + "/") {
                dirtyDirectories.insert(parentURL)
            }

            if changedURL.path == rootPath || changedURL.path.hasPrefix(rootPath + "/") {
                let isDirectory = (try? changedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory {
                    dirtyDirectories.insert(changedURL)
                }
            }
        }

        return dirtyDirectories.sorted { $0.path.count < $1.path.count }
    }

    static func shallowScan(at url: URL) -> [WorkspaceTreeShallowEntry] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: []
        ) else { return [] }

        return items.compactMap { itemURL -> WorkspaceTreeShallowEntry? in
            guard let values = try? itemURL.resourceValues(forKeys: scanResourceKeys),
                  let isDirectory = values.isDirectory else {
                return nil
            }
            let isHidden = values.isHidden == true
            guard shouldIncludeInTree(isDirectory: isDirectory, isHidden: isHidden) else {
                return nil
            }
            return (name: itemURL.lastPathComponent, url: itemURL, isDirectory: isDirectory == true)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func mergeNodes(
        existing: [FileNode],
        freshScan: [WorkspaceTreeShallowEntry]
    ) -> [FileNode] {
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return freshScan.map { item in
            if let existingNode = existingMap[item.url] {
                return existingNode
            }
            if item.isDirectory {
                let children = buildNodes(at: item.url, depth: 0)
                return FileNode(id: item.url, name: item.name, isDirectory: true, children: children)
            }
            return FileNode(id: item.url, name: item.name, isDirectory: false, children: nil)
        }
    }

    static func applyPartialUpdate(to nodes: [FileNode], at targetURL: URL) -> [FileNode] {
        let targetPath = targetURL.path
        return nodes.map { node in
            guard node.isDirectory else { return node }
            let nodePath = node.id.path
            if nodePath == targetPath {
                let freshScan = shallowScan(at: node.id)
                let mergedNodes = mergeNodes(existing: node.children ?? [], freshScan: freshScan)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: mergedNodes)
            }
            if targetPath.hasPrefix(nodePath + "/") {
                let updatedChildren = applyPartialUpdate(to: node.children ?? [], at: targetURL)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren)
            }
            return node
        }
    }

    static func buildNodes(at url: URL, depth: Int) -> [FileNode] {
        guard depth < 8 else { return [] }
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(scanResourceKeys),
            options: []
        ) else { return [] }

        return items.compactMap { itemURL -> FileNode? in
            guard let values = try? itemURL.resourceValues(forKeys: scanResourceKeys),
                  let isDirectory = values.isDirectory else {
                return nil
            }
            let isHidden = values.isHidden == true
            guard shouldIncludeInTree(isDirectory: isDirectory, isHidden: isHidden) else {
                return nil
            }
            if isDirectory == true {
                let children = buildNodes(at: itemURL, depth: depth + 1)
                return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: true, children: children)
            }
            return FileNode(id: itemURL, name: itemURL.lastPathComponent, isDirectory: false, children: nil)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func shouldIncludeInTree(isDirectory: Bool, isHidden: Bool) -> Bool {
        if isDirectory {
            return true
        }
        return !isHidden
    }
}

private final class LiveWorkspaceDirectoryObservation: WorkspaceDirectoryObservationSession, @unchecked Sendable {
    private var streamRef: FSEventStreamRef?

    init?(url: URL, onChange: @escaping ([String]) -> Void) {
        guard start(rootURL: url.standardizedFileURL, onChange: onChange) else { return nil }
    }

    deinit {
        stop()
    }

    private func start(rootURL: URL, onChange: @escaping ([String]) -> Void) -> Bool {
        final class CallbackBox {
            let fn: ([String]) -> Void

            init(_ fn: @escaping ([String]) -> Void) {
                self.fn = fn
            }
        }

        let callbackBox = Unmanaged.passRetained(CallbackBox(onChange))
        var context = FSEventStreamContext(
            version: 0,
            info: callbackBox.toOpaque(),
            retain: nil,
            release: { pointer in
                Unmanaged<CallbackBox>.fromOpaque(pointer!).release()
            },
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn(paths)
            },
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId.max,
            0.4,
            flags
        ) else {
            callbackBox.release()
            return false
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        streamRef = stream
        return true
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }
}