import Foundation

struct MemoryRuntimeSnapshotStore {
    private struct SnapshotHeader: Codable {
        var id: String
        var sessionId: String
        var createdAt: Date
    }

    private let fileManager: FileManager
    private let snapshotsDirectoryURL: URL
    private let legacyFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.snapshotsDirectoryURL = baseDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
        self.legacyFileURL = baseDirectory.appending(path: "runtime-snapshots.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func save(_ snapshot: MemoryRuntimeSnapshot) throws {
        try fileManager.createDirectory(at: snapshotsDirectoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: snapshot.id), options: .atomic)
    }

    func snapshot(id: String) throws -> MemoryRuntimeSnapshot? {
        let perFileURL = fileURL(for: id)
        if fileManager.fileExists(atPath: perFileURL.path) {
            let data = try Data(contentsOf: perFileURL)
            return try decoder.decode(MemoryRuntimeSnapshot.self, from: data)
        }
        return try loadLegacySnapshots().first(where: { $0.id == id })
    }

    func allSnapshots() throws -> [MemoryRuntimeSnapshot] {
        var snapshotsByID: [String: MemoryRuntimeSnapshot] = [:]

        for snapshot in try loadPerFileSnapshots() {
            snapshotsByID[snapshot.id] = snapshot
        }

        for snapshot in try loadLegacySnapshots() where snapshotsByID[snapshot.id] == nil {
            snapshotsByID[snapshot.id] = snapshot
        }

        return snapshotsByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    func latestSnapshotInMostRecentSession() throws -> MemoryRuntimeSnapshot? {
        let headers = try loadPerFileSnapshotHeaders()
        if let latestHeader = headers.max(by: { $0.createdAt < $1.createdAt }) {
            return try snapshot(id: latestHeader.id)
        }

        return try loadLegacySnapshots().max(by: { $0.createdAt < $1.createdAt })
    }

    func preferredSnapshot(snapshotID: String?, toolCallID: String?) throws -> MemoryRuntimeSnapshot? {
        if let snapshotID, !snapshotID.isEmpty,
           let snapshot = try snapshot(id: snapshotID) {
            return snapshot
        }

        if let toolCallID, !toolCallID.isEmpty,
           let snapshot = try allSnapshots().first(where: { $0.toolCallId == toolCallID }) {
            return snapshot
        }

        return try latestSnapshotInMostRecentSession()
    }

    private func loadPerFileSnapshots() throws -> [MemoryRuntimeSnapshot] {
        guard fileManager.fileExists(atPath: snapshotsDirectoryURL.path) else { return [] }

        return try fileManager.contentsOfDirectory(at: snapshotsDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(MemoryRuntimeSnapshot.self, from: data)
            }
    }

    private func loadPerFileSnapshotHeaders() throws -> [SnapshotHeader] {
        guard fileManager.fileExists(atPath: snapshotsDirectoryURL.path) else { return [] }

        return try fileManager.contentsOfDirectory(at: snapshotsDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SnapshotHeader.self, from: data)
            }
    }

    private func loadLegacySnapshots() throws -> [MemoryRuntimeSnapshot] {
        guard fileManager.fileExists(atPath: legacyFileURL.path) else { return [] }
        let data = try Data(contentsOf: legacyFileURL)
        return try decoder.decode([MemoryRuntimeSnapshot].self, from: data)
    }

    private func fileURL(for snapshotID: String) -> URL {
        snapshotsDirectoryURL.appending(path: "\(sanitizedFileName(snapshotID)).json")
    }

    private func sanitizedFileName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}