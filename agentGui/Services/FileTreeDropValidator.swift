// agentGui/Services/FileTreeDropValidator.swift
import Foundation

/// 对 FileTreeStore 所需只读访问的最小协议，方便测试使用同步 mock。
protocol StoreSnapshotProtocol {
    func entry(_ id: EntryID) -> FileEntry?
    func parentID(of id: EntryID) -> EntryID?
    func children(of id: EntryID) -> [EntryID]
}

/// 纯函数：验证并生成 FileTreeDropPlan。不依赖 UI，可在任意上下文调用。
enum FileTreeDropValidator {

    // MARK: - 内部拖放验证

    /// - Parameters:
    ///   - sourceIDs: 用户拖动的条目 ID（未去重）
    ///   - destinationID: 鼠标释放行的 EntryID（可能是文件或目录）
    ///   - snapshot: store 的只读快照
    ///   - isCopy: `true` = 复制（Option 键按下）
    /// - Returns: 合法的拖放计划；若无合法操作则 `nil`
    static func validate(
        sourceIDs: [EntryID],
        destinationID: EntryID,
        snapshot: StoreSnapshotProtocol,
        isCopy: Bool = false
    ) -> FileTreeDropPlan? {
        guard !sourceIDs.isEmpty else { return nil }

        // 1. 解析目标目录（文件 → 父目录）
        guard let resolvedDestination = resolveDestination(destinationID, snapshot: snapshot) else {
            return nil
        }

        // 2. 按深度排序（浅 → 深），然后去除嵌套源
        let pruned = pruneDescendants(sourceIDs, in: snapshot)
        guard !pruned.isEmpty else { return nil }

        // 3. 验证每个源相对于目标的合法性
        let valid = pruned.filter { sourceID in
            // 不能拖入自身
            if sourceID == resolvedDestination { return false }
            // 不能拖入后代
            if isDescendant(resolvedDestination, ofAnyOf: [sourceID], in: snapshot) { return false }
            // 不能拖入当前父目录（等价于无移动），复制模式下允许
            if !isCopy, snapshot.parentID(of: sourceID) == resolvedDestination { return false }
            return true
        }

        guard !valid.isEmpty else { return nil }
        return FileTreeDropPlan(draggedIDs: valid, destinationID: resolvedDestination, isMove: !isCopy)
    }

    // MARK: - 外部文件拖入验证

    static func validateExternalDrop(
        externalURLs: [URL],
        destinationID: EntryID,
        snapshot: StoreSnapshotProtocol
    ) -> FileTreeDropPlan? {
        guard !externalURLs.isEmpty else { return nil }
        guard let resolvedDestination = resolveDestination(destinationID, snapshot: snapshot) else {
            return nil
        }
        return FileTreeDropPlan(
            draggedIDs: [],
            destinationID: resolvedDestination,
            isMove: false,
            externalURLs: externalURLs
        )
    }

    // MARK: - 工具方法（internal 供测试直接调用）

    /// 若 id 对应文件，返回其父目录 ID；若对应目录，直接返回 id
    static func resolveDestination(_ id: EntryID, snapshot: StoreSnapshotProtocol) -> EntryID? {
        guard let entry = snapshot.entry(id) else { return nil }
        if entry.isDirectory { return id }
        return snapshot.parentID(of: id)
    }

    /// 检查 `candidate` 是否是 `ancestors` 中任意一个的后代（直接或间接）
    static func isDescendant(
        _ candidate: EntryID,
        ofAnyOf ancestors: [EntryID],
        in snapshot: StoreSnapshotProtocol
    ) -> Bool {
        var current = snapshot.parentID(of: candidate)
        while let parentID = current {
            if ancestors.contains(parentID) { return true }
            current = snapshot.parentID(of: parentID)
        }
        return false
    }

    /// 去除嵌套源：若某条目的祖先也在列表中，则移除该条目（保留顶层条目）。
    ///
    /// 算法：按路径深度升序排序后，对每个候选检查其所有祖先是否已在 `kept` 中。
    /// 时间复杂度 O(N * D)，N = 源数量，D = 树深度，实践中 N 很小。
    static func pruneDescendants(_ sourceIDs: [EntryID], in snapshot: StoreSnapshotProtocol) -> [EntryID] {
        // 按深度升序（浅节点先处理）
        let sorted = sourceIDs.sorted { a, b in
            depth(of: a, snapshot: snapshot) < depth(of: b, snapshot: snapshot)
        }

        var kept: [EntryID] = []
        for candidate in sorted {
            if !isDescendant(candidate, ofAnyOf: kept, in: snapshot) {
                kept.append(candidate)
            }
        }
        return kept
    }

    // MARK: - Private

    private static func depth(of id: EntryID, snapshot: StoreSnapshotProtocol) -> Int {
        var depth = 0
        var current = snapshot.parentID(of: id)
        while current != nil {
            depth += 1
            current = current.flatMap { snapshot.parentID(of: $0) }
        }
        return depth
    }
}
