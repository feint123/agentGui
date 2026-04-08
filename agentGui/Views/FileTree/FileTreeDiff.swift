// agentGui/Views/FileTree/FileTreeDiff.swift
import Foundation

/// `VisibleEntry` 列表变更的增量 diff 结果。
///
/// 计算逻辑参考：
/// - VSCode `List.splice(start, deleteCount, elements)` — 行级 insert/delete
///   并同步更新 selection/focus trait 索引（TraitSpliceable.splice）
/// - Zed `uniform_list` — 框架内部以 row ID 做 diff，驱动行级更新
///
/// `compute(from:to:threshold:)` 是纯静态函数，不依赖 AppKit，可直接单元测试。
struct FileTreeDiff {

    // MARK: - 结果字段

    /// 是否应放弃增量更新，降级为 `reloadData()`。
    ///
    /// 触发条件：
    /// 1. `old` 为空（首次加载，无需动画）
    /// 2. 结构变更数量超过 `threshold`（动画帧数过多会卡顿）
    let shouldFullReload: Bool

    /// 需要删除的行索引（基于 `old` 的索引）。
    let removals: IndexSet

    /// 需要插入的行索引（基于 `new` 的索引）。
    let insertions: IndexSet

    /// 结构不变（ID 相同）但内容字段变化的行索引（基于 `new` 的索引）。
    /// 用 `reloadData(forRowIndexes:)` 原地刷新，不触发动画。
    let contentReloads: IndexSet

    // MARK: - 计算入口

    /// 计算两个 `VisibleEntry` 列表之间的增量 diff。
    ///
    /// - Parameters:
    ///   - old: 当前 Coordinator 持有的旧列表。
    ///   - new: ViewModel 推送的新列表。
    ///   - threshold: 结构变更数量超出此阈值则降级为全量 reload，默认 200。
    /// - Returns: `FileTreeDiff` 描述所需操作。
    static func compute(
        from old: [VisibleEntry],
        to new: [VisibleEntry],
        threshold: Int = 200
    ) -> FileTreeDiff {

        // 首次加载（旧列表为空）→ 直接全量 reload，无需动画
        guard !old.isEmpty else {
            return FileTreeDiff(
                shouldFullReload: true,
                removals: .init(),
                insertions: .init(),
                contentReloads: .init()
            )
        }

        // 使用 Swift 标准库 CollectionDifference，按 ID 做等价判断
        let diff = new.difference(from: old) { $0.id == $1.id }

        var removals = IndexSet()
        var insertions = IndexSet()

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removals.insert(offset)
            case .insert(let offset, _, _):
                insertions.insert(offset)
            }
        }

        let totalStructuralChanges = removals.count + insertions.count

        // 变更量超过阈值 → 降级全量 reload（避免动画帧数过多卡顿）
        if totalStructuralChanges > threshold {
            return FileTreeDiff(
                shouldFullReload: true,
                removals: .init(),
                insertions: .init(),
                contentReloads: .init()
            )
        }

        // 无结构变更时检查内容变更
        // 内容变更：新旧列表中 ID 相同但 Equatable 比较不等的行
        var contentReloads = IndexSet()
        if diff.isEmpty {
            for (newIndex, newEntry) in new.enumerated() {
                if newIndex < old.count, old[newIndex].id == newEntry.id,
                   old[newIndex] != newEntry {
                    contentReloads.insert(newIndex)
                }
            }
        }

        return FileTreeDiff(
            shouldFullReload: false,
            removals: removals,
            insertions: insertions,
            contentReloads: contentReloads
        )
    }
}
