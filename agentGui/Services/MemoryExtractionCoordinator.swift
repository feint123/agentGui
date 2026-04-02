import Foundation

/// per-session 提取并发守卫。
/// 保证同一时刻一个 session 最多运行一次 extraction subagent。
actor MemoryExtractionCoordinator {
    private var isExtracting = false

    /// 查询当前是否可以启动新的提取。不修改状态。
    func shouldExtract() -> Bool {
        !isExtracting
    }

    /// 尝试占用提取槽位。若已被占用，返回 false；否则标记并返回 true。
    @discardableResult
    func beginExtraction() -> Bool {
        guard !isExtracting else { return false }
        isExtracting = true
        return true
    }

    /// 释放提取槽位。
    func finishExtraction() {
        isExtracting = false
    }
}
