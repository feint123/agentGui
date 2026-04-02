import Foundation

/// 将内存话题文件持久化到磁盘，并管理 MEMORY.md 索引。
///
/// nonisolated struct，但包含 FileManager I/O，调用方需保证在适当的上下文执行。
struct MemoryIndexFileSystem: Sendable {

    let memoryDir: URL
    private let fileManager: FileManager
    private let writer = MemoryIndexWriter()

    init(memoryDir: URL, fileManager: FileManager = .default) {
        self.memoryDir = memoryDir
        self.fileManager = fileManager
    }

    /// 从 `memoryDir` 下的实际 `.md` 文件重建 `MEMORY.md` 索引。
    ///
    /// 流程：
    /// 1. `MemoryTopicScanner` 扫描所有非 MEMORY.md 的 `.md` 文件并解析 frontmatter
    /// 2. 按 mtime 降序排序
    /// 3. 每个文件生成一行 `- [title](filename) — description`
    /// 4. 应用 `MemoryIndexWriter.truncate(lines:)` 的 200 行 / 25KB 限制
    /// 5. 写入 MEMORY.md
    ///
    /// 若扫描结果为空则不写 MEMORY.md（保留或不创建文件）。
    func rebuildFromDirectory() async throws {
        let headers = try await MemoryTopicScanner().scan(memoryDir: memoryDir)
        guard !headers.isEmpty else { return }

        try fileManager.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        // 构建索引行（mtime 已在 scanner 中降序排列）
        let indexLines: [String] = headers.map { header in
            let title = header.title ?? header.filename
            let baseLine = "- [\(title)](\(header.filename))"
            guard let rawDesc = header.description, !rawDesc.isEmpty else {
                return baseLine
            }
            let hook = rawDesc.count <= 150
                ? rawDesc
                : String(rawDesc.prefix(149)) + "…"
            return "\(baseLine) — \(hook)"
        }

        // 应用截断规则（200 行 / 25KB）
        let truncationResult = writer.truncate(lines: indexLines)

        // 写入 MEMORY.md
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        try truncationResult.content.write(to: indexURL, atomically: true, encoding: .utf8)
    }
}
