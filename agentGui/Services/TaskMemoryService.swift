//
//  TaskMemoryService.swift
//  agentGui
//
//  Persists structured TaskMemory to ~/.agentgui/task-memories/<sessionId>.json.
//  Uses the real system home directory (via getpwuid) to escape sandbox restrictions,
//  just like SkillService does for ~/.claude/skills.
//

import Foundation
import Darwin

// MARK: - TaskMemoryService

/// Reads and writes task-level memory files to ~/.agentgui/task-memories/.
final class TaskMemoryService {

    // MARK: - Singleton

    static let shared = TaskMemoryService()
    private init() {}

    // MARK: - Storage Directory

    private let storageDirectory: URL = {
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = NSHomeDirectory()
        }
        return URL(fileURLWithPath: realHome, isDirectory: true)
            .appending(path: ".agentgui/task-memories", directoryHint: .isDirectory)
    }()

    // MARK: - Public API

    /// Loads the persisted TaskMemory for a session, or `nil` if none exists yet.
    func load(sessionId: String) -> TaskMemory? {
        let url = fileURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TaskMemory.self, from: data)
    }

    /// Persists task memory to disk.  Creates the directory if necessary.
    func save(_ memory: TaskMemory) {
        ensureDirectoryExists()
        let url = fileURL(for: memory.sessionId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(memory) else {
            print("[TaskMemoryService] ❌ Failed to encode memory for session \(memory.sessionId)")
            return
        }
        do {
            try data.write(to: url, options: .atomicWrite)
            print("[TaskMemoryService] ✅ Saved task memory for session \(memory.sessionId)")
        } catch {
            print("[TaskMemoryService] ❌ Write error: \(error)")
        }
    }

    /// Merges a freshly-extracted TaskMemory into any existing on-disk record and saves.
    /// Returns the merged result.
    @discardableResult
    func mergeAndSave(extracted: TaskMemory, sessionId: String) -> TaskMemory {
        var current = load(sessionId: sessionId) ?? TaskMemory(sessionId: sessionId)
        current.merge(with: extracted)
        save(current)
        return current
    }

    /// Lists all session IDs that have persisted task memories.
    func allSessionIds() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Private

    private func fileURL(for sessionId: String) -> URL {
        storageDirectory.appending(path: "\(sessionId).json")
    }

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: storageDirectory.path) else { return }
        do {
            try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            print("[TaskMemoryService] Created storage directory at \(storageDirectory.path)")
        } catch {
            print("[TaskMemoryService] ❌ Could not create directory: \(error)")
        }
    }
}
