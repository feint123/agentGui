import Foundation
import SwiftAnthropic

/// 编排中段记忆召回全流程的服务。
///
/// 调用方（`MemoryRecallHook`）在 `.willStartRound` 时传入当前消息快照，
/// 本服务负责：
/// 1. 提取 query（最后一条 user 消息文本）
/// 2. 检查 session 字节上限
/// 3. 扫描 memory dir 的 topic file frontmatter
/// 4. 调用 side query（超时 2s）选出相关文件
/// 5. 读取文件内容并格式化为 `<system-reminder>` 注入块
///
/// nonisolated struct（无可变状态），会话状态由外部 `MemoryRecallSessionState` actor 管理。
struct RelevantMemoryRecallService: Sendable {

    let memoryDir: URL
    let sessionState: MemoryRecallSessionState
    let service: any AnthropicService

    /// side query 超时时限（秒）
    static let sideQueryTimeoutSeconds: Double = 2.0

    // MARK: - Main Entry

    /// 执行中段召回，返回注入文本（非 nil 则调用方将其插入消息链）。
    ///
    /// - Returns: 格式化后的 `<system-reminder>` 多块文本；无需注入时返回 `nil`。
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date = .now
    ) async -> String? {
        // 1. 提取 query
        guard let query = Self.extractUserQuery(from: messagesSnapshot) else { return nil }

        // 2. session 字节上限检查
        guard await !sessionState.isSessionByteLimitReached else { return nil }

        // 3. 扫描 topic files
        let headers = (try? await MemoryTopicScanner().scan(memoryDir: memoryDir)) ?? []
        guard !headers.isEmpty else { return nil }

        // 4. 已注入路径（传给 side query 预过滤）
        let alreadySurfaced = await sessionState.alreadySurfaced

        // 5. Side query（带超时）
        let selected = await withTimeout(seconds: Self.sideQueryTimeoutSeconds) {
            await RelevantMemorySideQuery().select(
                query: query,
                headers: headers,
                recentTools: Self.collectRecentToolNames(from: messagesSnapshot, maxRounds: 3),
                alreadySurfaced: alreadySurfaced,
                service: self.service
            )
        } ?? []

        guard !selected.isEmpty else { return nil }

        // 6. 读取文件内容并格式化注入块
        var blocks: [String] = []
        for header in selected {
            guard let content = try? String(contentsOf: header.filePath, encoding: .utf8) else { continue }
            let block = Self.formatInjectionBlock(
                filename: header.filename,
                content: content,
                mtimeMs: header.mtimeMs,
                now: now
            )
            blocks.append(block)
            // 记录已注入
            await sessionState.markSurfaced(path: header.filePath.path, byteCount: content.utf8.count)
        }

        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    // MARK: - Testable Static Helpers

    /// 从消息快照中提取最后一条 user 消息的文本。
    /// 单词数 < 2 时返回 nil（缺乏足够上下文）。
    static func extractUserQuery(from messages: [MessageParameter.Message]) -> String? {
        let lastUser = messages.last(where: { $0.role == "user" })
        guard let msg = lastUser else { return nil }
        let text: String
        switch msg.content {
        case .text(let t): text = t
        case .list(let blocks):
            text = blocks.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: " ")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 至少 2 个词，才有足够上下文
        guard trimmed.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
        return trimmed
    }

    /// 格式化单个文件内容为 `<system-reminder>` 注入块，附加陈旧性警告。
    static func formatInjectionBlock(
        filename: String,
        content: String,
        mtimeMs: Double,
        now: Date = .now
    ) -> String {
        let annotator = MemoryFreshnessAnnotator()
        let updatedAt = Date(timeIntervalSince1970: mtimeMs / 1000)
        let freshnessNote = annotator.freshnessNote(updatedAt: updatedAt, now: now)
        let header = "## Relevant Memory: \(filename)\n"
        return "<system-reminder>\n\(header)\(freshnessNote)\(content)\n</system-reminder>"
    }

    /// 从消息快照提取最近 N 轮 tool_use 名称（供 side query 过滤 reference 文件）。
    static func collectRecentToolNames(
        from messages: [MessageParameter.Message],
        maxRounds: Int
    ) -> [String] {
        // 从后往前遍历最近 maxRounds * 2 条消息（一轮 = assistant + user）
        let recent = messages.suffix(maxRounds * 2)
        var names: [String] = []
        for msg in recent {
            if case .list(let blocks) = msg.content {
                for block in blocks {
                    if case .toolUse(let id, let name, _) = block {
                        _ = id // 抑制 unused warning
                        if !names.contains(name) { names.append(name) }
                    }
                }
            }
        }
        return names
    }

    // MARK: - Private

    /// 带超时的 async 任务包装器。超时后返回 nil。
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }
}

// MARK: - Protocol

/// 召回服务的抽象协议，方便测试注入 mock。
protocol MemoryRecallServiceProtocol: Sendable {
    func recall(
        messagesSnapshot: [MessageParameter.Message],
        now: Date
    ) async -> String?
}

extension RelevantMemoryRecallService: MemoryRecallServiceProtocol {}
