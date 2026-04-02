import Foundation

/// 将内存话题文件持久化到磁盘，并管理 MEMORY.md 索引。
///
/// nonisolated struct，但包含 FileManager I/O，调用方需保证在适当的上下文执行。
struct MemoryIndexFileSystem: Sendable {

    let memoryDir: URL
    private let fileManager: FileManager

    init(memoryDir: URL, fileManager: FileManager = .default) {
        self.memoryDir = memoryDir
        self.fileManager = fileManager
    }

    /// M-07 占位实现。
    /// Feature M-07 将替换此方法为从 memoryDir 扫描 .md 文件重建 MEMORY.md 的实现。
    func rebuild() throws {
        // TODO(M-07): scan memoryDir/*.md frontmatter → build index → write MEMORY.md
    }
}
