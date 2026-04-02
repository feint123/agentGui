import Foundation

// MARK: - Memory Age Utilities
//
// 与 Claude Code `memoryAge.ts` 签名对齐的自由函数。
// `mtimeMs` 为 Unix 毫秒时间戳（来自 MemoryTopicHeader.mtimeMs）。
// 内部委托给 MemoryFreshnessAnnotator 避免逻辑重复。
//
// 与 MemoryFreshnessAnnotator 的分工：
//   - MemoryFreshnessAnnotator：Date 参数，供 UI 等已有 Date 对象的调用方使用
//   - MemoryAge（本文件）：mtimeMs: Double 参数，供 prompt 构建等直接处理扫描结果的调用方使用

private let _annotator = MemoryFreshnessAnnotator()

/// 距 `mtimeMs`（Unix 毫秒）的整数天数（floor-rounded）。
/// 未来时间戳截断到 0（应对时钟偏差）。
///
/// 对齐 Claude Code `memoryAgeDays(mtimeMs: number): number`
func memoryAgeDays(_ mtimeMs: Double, now: Date = .now) -> Int {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.ageDays(updatedAt: updatedAt, now: now)
}

/// `mtimeMs` 对应的人类可读年龄字符串（英文，供模型 prompt 使用）：
/// - 0 天 → "today"
/// - 1 天 → "yesterday"
/// - N 天 → "N days ago"
///
/// 对齐 Claude Code `memoryAge(mtimeMs: number): string`
///
/// > 注：UI 层需要中文时，请使用 `MemoryFreshnessAnnotator.ageText()`。
func memoryAge(_ mtimeMs: Double, now: Date = .now) -> String {
    let d = memoryAgeDays(mtimeMs, now: now)
    switch d {
    case 0:  return "today"
    case 1:  return "yesterday"
    default: return "\(d) days ago"
    }
}

/// 仅对 > 1 天的记忆返回纯文本陈旧性警告；否则返回空字符串。
///
/// 对齐 Claude Code `memoryFreshnessText(mtimeMs: number): string`
func memoryFreshnessText(_ mtimeMs: Double, now: Date = .now) -> String {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.freshnessText(updatedAt: updatedAt, now: now)
}

/// 带 `<system-reminder>` 包裹的陈旧性警告（末尾含换行）。
/// > 1 天时返回完整节；否则返回空字符串。
///
/// 对齐 Claude Code `memoryFreshnessNote(mtimeMs: number): string`
func memoryFreshnessNote(_ mtimeMs: Double, now: Date = .now) -> String {
    let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
    return _annotator.freshnessNote(updatedAt: updatedAt, now: now)
}
