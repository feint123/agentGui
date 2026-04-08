// agentGui/Services/FileScanning.swift
import Foundation

/// 文件系统浅扫描结果条目。
struct ScannedEntry: Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// 文件系统扫描抽象。
/// 产品代码使用 `RealFileScanner`；测试注入 `MockFileScanner`。
///
/// 参考 Zed `project_panel.rs` 中对 Worktree / Project 的依赖注入模式：
/// ProjectPanel 通过 Entity<Project> 访问文件系统，
/// 我们通过协议实现同等的可测试性隔离。
protocol FileScanning: Sendable {
    func shallowScan(directory: URL) async throws -> [ScannedEntry]
    func isDirectory(_ url: URL) async -> Bool
}

/// 实现：读取真实磁盘。
struct RealFileScanner: FileScanning {
    func shallowScan(directory: URL) async throws -> [ScannedEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        )
        return contents.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return ScannedEntry(
                url: url.standardizedFileURL,
                name: url.lastPathComponent,
                isDirectory: isDir
            )
        }
    }

    func isDirectory(_ url: URL) async -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }
}
