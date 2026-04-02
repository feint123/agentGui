import Foundation

/// 将 `MemoryIndexWriter` 的输出持久化到磁盘。
///
/// - 在 `memoryDir` 下写 `MEMORY.md`（索引）和各话题 `.md` 文件
/// - 幂等：重建时覆盖旧 `MEMORY.md`；话题文件按需覆写
/// - 若 `records` 为空则跳过写入（不创建空的 MEMORY.md）
///
/// nonisolated struct，但包含 FileManager I/O，调用方需保证在适当的上下文执行。
struct MemoryIndexFileSystem: Sendable {

    let memoryDir: URL
    private let writer = MemoryIndexWriter()
    private let fileManager: FileManager

    init(memoryDir: URL, fileManager: FileManager = .default) {
        self.memoryDir = memoryDir
        self.fileManager = fileManager
    }

    /// 根据 `records` 重建 MEMORY.md 和话题文件。
    /// - Throws: 文件写入失败时抛出 `CocoaError`。
    func rebuild(with records: [MemoryRecord], now: Date = .now) throws {
        let output = writer.build(records: records, now: now)
        guard !output.indexContent.isEmpty else { return }

        try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        // 写话题文件
        for (filename, content) in output.topicFiles {
            let url = memoryDir.appendingPathComponent(filename)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        // 写 MEMORY.md
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        try output.indexContent.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}
