import Foundation

/// 计算记忆条目年龄并生成陈旧性警告文本。
///
/// 对齐 Claude Code `memoryAge.ts` 的设计：
/// - 用人类可读的 "N days old" 替代原始 ISO 时间戳，
///   因为模型不善做日期计算，而 "47 days ago" 能直接触发陈旧性推理。
/// - 仅对 > 1 天的记忆输出警告，避免 today/yesterday 引入噪音。
///
/// nonisolated struct，无副作用，可在任意并发上下文调用。
struct MemoryFreshnessAnnotator: Sendable {

    /// 距 `updatedAt` 的整数天数（floor-rounded）。
    ///
    /// - 今天更新 → 0；昨天 → 1；N 天前 → N
    /// - 未来时间戳（时钟偏差）截断到 0
    func ageDays(updatedAt: Date, now: Date = .now) -> Int {
        max(0, Int((now.timeIntervalSince1970 - updatedAt.timeIntervalSince1970) / 86_400))
    }

    /// 人类可读的年龄字符串，供 UI 列表显示：今天 / 昨天 / N 天前。
    func ageText(updatedAt: Date, now: Date = .now) -> String {
        let d = ageDays(updatedAt: updatedAt, now: now)
        switch d {
        case 0:  return "今天"
        case 1:  return "昨天"
        default: return "\(d) 天前"
        }
    }

    /// 仅对 > 1 天的记忆返回纯文本陈旧性警告；否则返回空字符串。
    func freshnessText(updatedAt: Date, now: Date = .now) -> String {
        let d = ageDays(updatedAt: updatedAt, now: now)
        guard d > 1 else { return "" }
        return "This memory is \(d) days old. " +
               "Memories are point-in-time observations, not live state — " +
               "claims about code behavior or file:line citations may be outdated. " +
               "Verify against current code before asserting as fact."
    }

    /// 带 `<system-reminder>` 包裹的版本，用于 topic file 内嵌注入。
    ///
    /// > 1 天时返回完整 reminder 节（末尾带换行）；否则返回空字符串。
    func freshnessNote(updatedAt: Date, now: Date = .now) -> String {
        let text = freshnessText(updatedAt: updatedAt, now: now)
        guard !text.isEmpty else { return "" }
        return "<system-reminder>\(text)</system-reminder>\n"
    }
}
