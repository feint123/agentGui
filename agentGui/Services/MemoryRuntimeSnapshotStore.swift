import Foundation

struct MemoryRuntimeSnapshotStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = baseDirectory.appending(path: "runtime-snapshots.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func save(_ snapshot: MemoryRuntimeSnapshot) throws {
        let baseDirectory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        var snapshots = try loadAll()
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        let data = try encoder.encode(snapshots.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: fileURL, options: .atomic)
    }

    func snapshot(id: String) throws -> MemoryRuntimeSnapshot? {
        try loadAll().first(where: { $0.id == id })
    }

    func allSnapshots() throws -> [MemoryRuntimeSnapshot] {
        try loadAll().sorted { $0.createdAt > $1.createdAt }
    }

    private func loadAll() throws -> [MemoryRuntimeSnapshot] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([MemoryRuntimeSnapshot].self, from: data)
    }
}