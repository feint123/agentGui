//
//  ClaudeService+ContextCompression.swift
//  agentGui
//
//  Compresses the conversation history by summarizing old messages when the
//  context window usage exceeds 75%.
//

import Foundation
import SwiftAnthropic

extension ClaudeService {

    // MARK: - Constants

    /// Compression fires when input token usage exceeds this fraction of the context window.
    private static let compressionThreshold: Double = 0.75

    /// Number of most-recent messages to keep verbatim after compression.
    private static let recentMessageCount: Int = 6

    // MARK: - Public API

    /// Checks whether context usage is above the threshold and, if so, compresses the
    /// message history in-place.  Safe to call even when `currentInputTokens == 0`.
    func compressIfNeeded(
        messages: inout [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String
    ) async {
        guard currentInputTokens > 0,
              contextUsageRatio > Self.compressionThreshold,
              messages.count > Self.recentMessageCount + 2 else { return }

        let cutoff = messages.count - Self.recentMessageCount
        let oldMessages = Array(messages[..<cutoff])
        let recentMessages = Array(messages[cutoff...])

        print("Context compression triggered: \(currentInputTokens) tokens (\(Int(contextUsageRatio * 100))%), compressing \(oldMessages.count) messages → summary + \(recentMessages.count) recent")

        guard let summary = await summarize(messages: oldMessages, service: service, modelId: modelId) else {
            print("Context compression: summarization failed, skipping")
            return
        }

        // Replace history with: [summary exchange] + [recent messages]
        messages = [
            MessageParameter.Message(
                role: .user,
                content: .text("以下是之前对话的摘要，请在后续回复中记住这些上下文：\n\n\(summary)")
            ),
            MessageParameter.Message(
                role: .assistant,
                content: .text("好的，我已了解之前对话的上下文，将继续基于这些信息为您提供帮助。")
            )
        ] + recentMessages

        currentInputTokens = 0
        print("Context compression complete: history replaced with summary + \(recentMessages.count) recent messages")
    }

    // MARK: - Private Helpers

    private func summarize(
        messages: [MessageParameter.Message],
        service: any AnthropicService,
        modelId: String
    ) async -> String? {
        let transcript = messages.map { msg in
            let role = msg.role == "user" ? "用户" : "助手"
            let text = extractText(from: msg.content)
            return "[\(role)]: \(text)"
        }.joined(separator: "\n\n")

        let prompt = """
        请将以下对话历史进行全面但简洁的摘要。摘要应覆盖：
        1. 用户的主要目标和请求
        2. 已完成的主要工作和重要决策
        3. 当前状态和待完成的事项
        4. 重要的技术细节、文件路径、代码片段等

        请用中文输出摘要。

        对话历史：
        \(transcript)
        """

        let params = MessageParameter(
            model: .other(modelId),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 4096
        )

        do {
            let response = try await service.createMessage(params)
            return response.content.compactMap { block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }.joined(separator: "\n")
        } catch {
            print("Context compression: summarize error: \(error)")
            return nil
        }
    }

    /// Extracts a plain-text representation from a `MessageParameter.Message.Content` value.
    private func extractText(from content: MessageParameter.Message.Content) -> String {
        switch content {
        case .text(let str):
            return str
        case .list(let objects):
            return objects.compactMap { (obj: MessageParameter.Message.Content.ContentObject) -> String? in
                switch obj {
                case .text(let str): return str
                case .toolUse(_, let name, _): return "[工具调用: \(name)]"
                case .toolResult(_, let result, _, _): return "[工具结果: \(String(result.prefix(200)))]"
                default: return nil
                }
            }.joined(separator: " ")
        }
    }
}
