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
    /// 是否为内联编辑占位行（FT-R8）。
    ///
    /// 对标 Zed `NEW_ENTRY_ID = ProjectEntryId::MAX` sentinel：
    /// Zed 用最大值 ID 标记占位条目；本实现用显式布尔字段，更类型安全。
    /// 正常构造函数传 false；`VisibleEntry.placeholder(depth:parentID:)` 工厂传 true。
    var isEditPlaceholder: Bool = false
}

// MARK: - FT-R8 占位行工厂

extension VisibleEntry {
    /// 创建一个内联编辑占位行（`isEditPlaceholder = true`）。
    ///
    /// 对标 Zed `add_entry(is_dir, cx)` 中以 `NEW_ENTRY_ID` sentinel 插入的条目。
    ///
    /// - Parameters:
    ///   - depth:    缩进层级（与同级条目相同）
    ///   - parentID: 父目录 EntryID（上下文用，不作为占位行自身的真实 ID）
    static func placeholder(depth: Int, parentID: EntryID) -> VisibleEntry {
        VisibleEntry(
            id: .placeholderSentinel,
            name: "",
            isDirectory: false,
            depth: depth,
            isExpanded: false,
            loadState: .loaded,
            foldedAncestors: nil,
            gitSummary: nil,
            diagnosticSeverity: nil,
            isIgnored: false,
            isEditPlaceholder: true
        )
    }
}

extension EntryID {
    /// FT-R8 占位行专用 sentinel（对标 Zed `NEW_ENTRY_ID = ProjectEntryId::MAX`）。
    /// 不会出现在 `FileTreeStore.entries` 中，仅在 `visibleEntries` 临时存在。
    static let placeholderSentinel = EntryID(url: URL(string: "about:new-entry-placeholder")!)
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
