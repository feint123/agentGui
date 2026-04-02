import Foundation

/// 文件级乐观锁：管理 `<memoryDir>/.consolidate-lock`。
///
/// 设计对齐 Claude Code `consolidationLock.ts`：
/// - lock 文件的 mtime = lastConsolidatedAt（读取后可判断是否到整合时间）
/// - lock 文件的 body = 持有者 PID（防止其他进程或旧 PID 遗留锁死）
/// - `tryAcquire()` 返回 prior mtime（用于失败时 rollback），竞争失败返回 `nil`
/// - `rollback(to:)` 将 mtime 恢复到 priorMtime（0 则删除文件）
/// - `commitConsolidation()` 将 mtime 更新为 now（整合成功后调用）
struct MemoryConsolidationLockManager: Sendable {

    private static let lockFileName = ".consolidate-lock"
    /// 超过此时长认为 PID 已死（PID 复用防护）。
    private static let holderStaleDurationSeconds: TimeInterval = 3600

    let memoryDir: URL

    private var lockFileURL: URL {
        memoryDir.appendingPathComponent(Self.lockFileName)
    }

    // MARK: - Public API

    /// 返回 lock 文件的 mtime（毫秒），等同于 `lastConsolidatedAt`。
    /// 文件不存在时返回 0。
    func readLastConsolidatedAt() async throws -> Double {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: lockFileURL.path)
            guard let mtime = attrs[.modificationDate] as? Date else { return 0 }
            return mtime.timeIntervalSince1970 * 1000
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return 0
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return 0
        }
        // 其他 I/O 错误向上抛出
    }

    /// 尝试获取锁。
    ///
    /// - 返回 prior mtime（毫秒）：成功获取。调用方在失败时应调用 `rollback(to:)`。
    /// - 返回 `nil`：另一个有效的持有者存在（竞争失败）。
    func tryAcquire() async throws -> Double? {
        let path = lockFileURL.path
        var priorMtime: Double = 0
        var holderPID: Int?

        // 读取现有 lock（ENOENT → 无 prior lock）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = attrs[.modificationDate] as? Date {
            priorMtime = mtime.timeIntervalSince1970 * 1000
            if let body = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int(body.trimmingCharacters(in: .whitespacesAndNewlines)) {
                holderPID = pid
            }
        }

        // 若 lock 存在且在 stale 期内
        if priorMtime > 0 {
            let ageSeconds = (Date.now.timeIntervalSince1970 * 1000 - priorMtime) / 1000
            if ageSeconds < Self.holderStaleDurationSeconds {
                if let pid = holderPID, isProcessRunning(pid: pid) {
                    return nil  // 有效持有者，竞争失败
                }
                // 持有者已死（继续覆写）
            }
        }

        // 写入本进程 PID，mtime = now
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: lockFileURL, atomically: true, encoding: .utf8)

        // 验证：双写竞争时最后一个 write 赢，读回 PID 确认是自己
        guard let readBack = try? String(contentsOf: lockFileURL, encoding: .utf8),
              Int(readBack.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(pid) else {
            return nil  // 竞争失败
        }

        return priorMtime
    }

    /// 将 lock 文件 mtime 恢复到 `priorMtime`（毫秒）。
    ///
    /// - `priorMtime == 0`：删除 lock 文件（恢复到无文件状态）。
    func rollback(to priorMtime: Double) async throws {
        let path = lockFileURL.path
        if priorMtime == 0 {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        // 清空 body，避免本进程看起来仍在持有
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        // 恢复 mtime
        let date = Date(timeIntervalSince1970: priorMtime / 1000)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path
        )
    }

    /// 将 lock 文件 mtime 更新为 now（整合成功后调用）。
    func commitConsolidation() async throws {
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: lockFileURL, atomically: true, encoding: .utf8)
        // mtime 已被 write(atomically:) 更新为 now，无需额外设置
    }

    // MARK: - Private

    private func isProcessRunning(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0  // kill(pid, 0) 仅检查存在性，不发送信号
    }
}
