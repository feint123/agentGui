// agentGui/Models/FileEntry.swift
import Foundation

/// 文件树条目唯一标识符，以 URL 为键。
struct EntryID: Hashable, Sendable, Comparable {
    let url: URL

    static func < (lhs: EntryID, rhs: EntryID) -> Bool {
        lhs.url.path < rhs.url.path
    }
}

/// 文件树中一个条目的值类型快照（目录或文件）。
/// 不持有 children，由 `FileTreeStore.children` 邻接表管理。
///
/// 对比旧 `FileNode`：
/// - 旧：`children: [FileNode]?` 递归嵌套，更新一个节点需遍历整棵树。
/// - 新：`children` 存储在 Actor 的 `[EntryID: [EntryID]]` 邻接表中，更新 O(1)。
/// - 旧：`foldedSegments: [String]` 存在模型里（持久化）。
/// - 新：Auto-fold 只在 `computeVisibleEntries` 计算，不存入 `FileEntry`。
struct FileEntry: Sendable {
    let id: EntryID
    let name: String
    let isDirectory: Bool
    let parentID: EntryID?
    var loadState: LoadState

    init(
        id: EntryID,
        name: String,
        isDirectory: Bool,
        parentID: EntryID?,
        loadState: LoadState = .notLoaded
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.parentID = parentID
        self.loadState = loadState
    }

    enum LoadState: Equatable, Sendable {
        case notLoaded   // 目录：尚未扫描子条目
        case loading     // 正在扫描
        case loaded      // 已扫描（children 存储在 Store 中）
    }
}
