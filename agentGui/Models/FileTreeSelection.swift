// agentGui/Models/FileTreeSelection.swift
import Foundation

/// 键盘/鼠标选择状态。存储在 `FileTreeViewModel`（@MainActor），不入 Store。
///
/// 对比旧 `WorkspaceTreeViewModel`:
/// - 旧：`selectedTreeNodeID: URL?` + `selectedTreeNodeIDs: Set<URL>`（无序）
/// - 新：`primary` + `selected: [EntryID]`（保序，支持多选拖拽顺序）
///         + `anchor: EntryID?`（支持 Shift-click 范围选择）
struct FileTreeSelection: Sendable {
    var primary: EntryID?
    var selected: [EntryID] = []
    var anchor: EntryID?

    /// 将条目插入选中集合（保序，幂等）。
    mutating func add(_ id: EntryID) {
        if !selected.contains(id) {
            selected.append(id)
        }
        primary = id
    }

    /// 切换单选（Cmd+Click）。
    mutating func toggle(_ id: EntryID) {
        if let idx = selected.firstIndex(of: id) {
            selected.remove(at: idx)
            primary = selected.last
        } else {
            add(id)
        }
    }

    /// 设置单一主选项（普通 Click）。
    mutating func setSingle(_ id: EntryID) {
        selected = [id]
        primary = id
        anchor = id
    }

    var isEmpty: Bool { selected.isEmpty }
}
