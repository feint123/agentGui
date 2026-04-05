// agentGui/Services/Rewind/FileBackupStore.swift
import CryptoKit
import Foundation

// MARK: - Errors

enum FileBackupStoreError: Error, Sendable {
    case backupFileNotFound(backupKey: String, sessionID: String)
    case pathTraversalDetected(path: String)
}

// MARK: - FileBackupStore

/// 以内容寻址方式在磁盘上管理文件备份。
///
/// - 备份路径：`~/.agentgui/checkpoints/{sessionID}/{key[:2]}/{key}.bak`
/// - `key` = `{sha256(content)}.v{version}`
/// - 相同内容不重复写入（idempotent）。
/// - 线程安全：`actor` 序列化所有状态访问；实际磁盘 IO 在内部调用，可安全并发。
actor FileBackupStore: Sendable {

    // MARK: - Configuration

    private let checkpointsBaseURL: URL

    // MARK: - Init

    init(baseURL: URL? = nil) {
        checkpointsBaseURL = baseURL
            ?? ConfigDirectoryManager.shared.agentGuiDir
                .appendingPathComponent("checkpoints", isDirectory: true)
    }

    // MARK: - Public API

    /// 备份 `filePath` 当前内容（修改前调用）。
    /// 若文件不存在，返回 `backupKey == nil` 的 entry（表示该文件此时不存在）。
    /// 相同内容多次调用幂等——不重复写入磁盘。
    func createBackup(
        filePath: String,
        sessionID: String,
        version: Int
    ) async throws -> FileBackupEntry {
        let fm = FileManager.default

        // 读取源文件，若不存在返回 nil-key entry
        guard let sourceData = fm.contents(atPath: filePath) else {
            return FileBackupEntry(
                backupKey: nil,
                version: version,
                backupTime: Date(),
                originalRelativePath: filePath
            )
        }

        // 内容哈希 → backupKey
        let hash = SHA256.hash(data: sourceData)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        let backupKey = "\(hash).v\(version)"

        let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)

        // 幂等：若备份文件已存在且大小相同，直接返回（同内容不重写）
        if let existingSize = try? backupFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existingSize == sourceData.count {
            return FileBackupEntry(
                backupKey: backupKey,
                version: version,
                backupTime: Date(),
                originalRelativePath: filePath
            )
        }

        // lazy mkdir + 写入
        let backupDir = backupFileURL.deletingLastPathComponent()
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try sourceData.write(to: backupFileURL, options: .atomic)

        return FileBackupEntry(
            backupKey: backupKey,
            version: version,
            backupTime: Date(),
            originalRelativePath: filePath
        )
    }

    /// 文件当前内容是否与备份不同。
    /// `entry.backupKey == nil`：检查文件现在是否存在（存在则认为"已变化"）。
    /// 使用 stat 快速路径：size + mode 相同且 mtime < 备份文件 mtime 时直接返回 false。
    func hasFileChanged(
        filePath: String,
        sessionID: String,
        entry: FileBackupEntry
    ) async -> Bool {
        let fm = FileManager.default

        guard let backupKey = entry.backupKey else {
            // nil backupKey 表示文件在快照时不存在；若现在存在则"已变化"
            return fm.fileExists(atPath: filePath)
        }

        let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)

        guard let sourceAttrs = try? fm.attributesOfItem(atPath: filePath),
              let backupAttrs = try? fm.attributesOfItem(atPath: backupFileURL.path) else {
            // 其中一个文件不可读（可能已被删除）→ 视为已变化
            return true
        }

        let sourceSize = sourceAttrs[.size] as? Int ?? -1
        let backupSize = backupAttrs[.size] as? Int ?? -2
        guard sourceSize == backupSize else { return true }

        // mtime 快速路径：源文件比备份旧 → 内容未变
        if let sourceMtime = sourceAttrs[.modificationDate] as? Date,
           let backupMtime = backupAttrs[.modificationDate] as? Date,
           sourceMtime < backupMtime {
            return false
        }

        // 内容完整对比
        guard let sourceData = fm.contents(atPath: filePath),
              let backupData = fm.contents(atPath: backupFileURL.path) else {
            return true
        }
        return sourceData != backupData
    }

    /// 从备份恢复文件内容。
    /// 若 `entry.backupKey == nil`，删除 `filePath`（该文件在快照时不存在）。
    func restoreFile(
        filePath: String,
        sessionID: String,
        from entry: FileBackupEntry
    ) async throws {
        let fm = FileManager.default

        guard let backupKey = entry.backupKey else {
            // nil → 删除目标文件（快照时文件不存在）
            do {
                try fm.removeItem(atPath: filePath)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
                // 已不存在，幂等
            }
            return
        }

        let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)
        guard fm.fileExists(atPath: backupFileURL.path) else {
            throw FileBackupStoreError.backupFileNotFound(backupKey: backupKey, sessionID: sessionID)
        }

        // 恢复：lazy mkdir → copyFile（覆盖目标）
        let targetURL = URL(fileURLWithPath: filePath)
        let targetDir = targetURL.deletingLastPathComponent()
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: filePath) {
            try fm.removeItem(atPath: filePath)
        }
        try fm.copyItem(at: backupFileURL, to: targetURL)
    }

    /// 删除指定 session 下的所有备份文件（GC 入口）。
    func deleteBackups(forSession sessionID: String) async {
        let sessionDir = sessionBaseURL(sessionID: sessionID)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    // MARK: - Internal Path Helpers

    private func backupURL(backupKey: String, sessionID: String) -> URL {
        let shard = String(backupKey.prefix(2))
        return checkpointsBaseURL
            .appendingPathComponent(sessionID)
            .appendingPathComponent(shard)
            .appendingPathComponent("\(backupKey).bak")
    }

    private func sessionBaseURL(sessionID: String) -> URL {
        checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
    }
}
