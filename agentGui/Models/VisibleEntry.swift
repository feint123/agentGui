// agentGui/Models/VisibleEntry.swift
import Foundation

/// 可见行的渲染快照——每一行对应一个 `VisibleEntry`。
/// 由 `FileTreeStore.computeVisibleEntries()` 在 actor 内生成，
/// 经 `@MainActor` 推送到 `FileTreeViewModel.visibleEntries`。
struct VisibleEntry: Identifiable, Equatable, Sendable {
    let id: EntryID
    let name: String
    let isDirectory: Bool
    let depth: Int
    let isExpanded: Bool
    /// 目录的加载状态——Cell 据此决定是否显示 NSProgressIndicator。
    /// 参考 Zed `EntryDetails.is_dir_scanning`（project_panel.rs）。
    let loadState: FileEntry.LoadState
    /// 非 nil 表示该节点是 Auto-fold 链的"叶节点"，需渲染多段路径。
    /// 参考 Zed `FoldedAncestors`（project_panel.rs）的 `ancestors` vec。
    let foldedAncestors: FoldedAncestors?
    let gitSummary: GitSummary?
    let diagnosticSeverity: DiagSeverity?
    let isIgnored: Bool
}

/// 单子目录压缩链的描述，对应 Zed 的 `FoldedAncestors.ancestors`。
///
/// 例如 src → src/main → src/main/java 压缩后:
///   segments = [("src", id_src), ("main", id_main), ("java", id_java)]
///   terminalID = id_java
///
/// 与旧 `FileNode.foldedSegments: [String]` 的区别：
/// - 每段携带 `entryID`，支持点击任意段展开（Zed 风格）
/// - 不在模型中持久化，仅在 computeVisibleEntries() 时计算
struct FoldedAncestors: Equatable, Sendable {
    let segments: [FoldedSegment]
    let terminalID: EntryID

    struct FoldedSegment: Equatable, Sendable {
        let name: String
        let entryID: EntryID
    }
}
