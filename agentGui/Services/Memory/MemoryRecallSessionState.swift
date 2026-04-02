import Foundation
import SwiftAnthropic

/// Session 级别的记忆召回状态，跨轮维护去重信息。
///
/// - `alreadySurfaced`：本 session 内已注入过的 topic file 绝对路径集合。
/// - `totalBytesSurfaced`：本 session 累计注入字节数（用于防止 token 膨胀）。
/// - AutoCompact 发生时调用 `syncFrom(messagesSnapshot:)` 根据当前消息快照重建状态。
///   由于 compact 后旧的 system-reminder 消息被移除，重建后 alreadySurfaced 清空，
///   允许再次召回——与 Claude Code 的 `collectSurfacedMemories` 原理相同。
///
/// actor isolation 保证并发安全（hook 和 service 均在不同 Task 中访问）。
actor MemoryRecallSessionState {

    /// session 内累计注入的字节上限（~50KB）。
    static let maxSessionBytes = 51_200

    private(set) var alreadySurfaced: Set<String> = []
    private(set) var totalBytesSurfaced: Int = 0

    var isSessionByteLimitReached: Bool {
        totalBytesSurfaced >= Self.maxSessionBytes
    }

    func markSurfaced(path: String, byteCount: Int) {
        alreadySurfaced.insert(path)
        totalBytesSurfaced += byteCount
    }

    /// 根据当前消息快照重建 `alreadySurfaced`。
    ///
    /// AutoCompact 后旧消息被丢弃，注入过的 system-reminder 也随之消失，
    /// 因此直接清空状态，允许重新召回。
    ///
    /// 如果未来需要从消息内容提取已注入文件路径，可在此解析
    /// `<system-reminder>` 标签，类比 Claude Code `collectSurfacedMemories`。
    func syncFrom(messagesSnapshot: [MessageParameter.Message]) {
        // 简单策略：消息快照中无 system-reminder 时全清。
        let hasAnyReminder = messagesSnapshot.contains { msg in
            let text: String
            switch msg.content {
            case .text(let t): text = t
            case .list(let blocks):
                text = blocks.compactMap {
                    if case .text(let t) = $0 { return t }
                    return nil
                }.joined()
            }
            return text.contains("<system-reminder>")
        }
        if !hasAnyReminder {
            alreadySurfaced = []
            totalBytesSurfaced = 0
        }
    }
}
