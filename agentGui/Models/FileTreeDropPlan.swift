// agentGui/Models/FileTreeDropPlan.swift
import Foundation

/// 拖放决策结果。由 FileTreeDropValidator 产生，由 FileTreeDropExecutor 消费。
struct FileTreeDropPlan: Sendable, Equatable {
    /// 去重、裁剪嵌套后的源条目 ID 列表（顺序保留拖拽时的视觉顺序）
    let draggedIDs: [EntryID]

    /// 解析后的目标目录 ID。若用户拖到文件行上，会自动提升到该文件的父目录。
    let destinationID: EntryID

    /// `true` = 移动（默认），`false` = 复制（Option 键或外部文件）
    let isMove: Bool

    /// 外部文件 URL（仅外部拖入时非空）
    let externalURLs: [URL]

    init(
        draggedIDs: [EntryID],
        destinationID: EntryID,
        isMove: Bool = true,
        externalURLs: [URL] = []
    ) {
        self.draggedIDs = draggedIDs
        self.destinationID = destinationID
        self.isMove = isMove
        self.externalURLs = externalURLs
    }
}
