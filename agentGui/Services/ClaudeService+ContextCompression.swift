//
//  ClaudeService+ContextCompression.swift
//  agentGui
//
//  Compresses old messages into a hierarchical memory structure (分层记忆) instead of a
//  flat paragraph summary.  Memory layers:
//    用户目标 / 已完成动作 / 未完成动作 / 关键文件路径 / 失败与约束 / 语义事实
//

import Foundation
import SwiftAnthropic

// MARK: - ContextMemory

/// Structured hierarchical memory produced by context compression.
/// Replaces the flat "整段摘要" approach with distinct, independently updatable layers.
struct ContextMemory {
    var userGoal: String = ""
    var completedActions: [String] = []
    var pendingActions: [String] = []
    var keyFilesAndPaths: [String] = []
    var failuresAndConstraints: [String] = []
    var semanticFacts: [String] = []

    var isEmpty: Bool {
        userGoal.isEmpty && completedActions.isEmpty && pendingActions.isEmpty
            && keyFilesAndPaths.isEmpty && failuresAndConstraints.isEmpty && semanticFacts.isEmpty
    }

    /// Merge a newer snapshot into this memory.
    /// Goal takes the newer value; pending replaces if the newer set is non-empty;
    /// completed / files / failures / facts accumulate with deduplication.
    mutating func merge(with newer: ContextMemory) {
        if !newer.userGoal.isEmpty { userGoal = newer.userGoal }
        completedActions = contextMemoryDeduped(completedActions + newer.completedActions)
        if !newer.pendingActions.isEmpty { pendingActions = newer.pendingActions }
        keyFilesAndPaths = contextMemoryDeduped(keyFilesAndPaths + newer.keyFilesAndPaths)
        failuresAndConstraints = contextMemoryDeduped(failuresAndConstraints + newer.failuresAndConstraints)
        semanticFacts = contextMemoryDeduped(semanticFacts + newer.semanticFacts)
    }

    /// Renders the memory as structured text for injection into the conversation.
    func toPromptText() -> String {
        var parts: [String] = []
        if !userGoal.isEmpty {
            parts.append("## 用户目标\n\(userGoal)")
        }
        if !completedActions.isEmpty {
            parts.append("## 已完成动作\n" + completedActions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !pendingActions.isEmpty {
            parts.append("## 未完成动作\n" + pendingActions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !keyFilesAndPaths.isEmpty {
            parts.append("## 关键文件/路径\n" + keyFilesAndPaths.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !failuresAndConstraints.isEmpty {
            parts.append("## 失败与约束\n" + failuresAndConstraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !semanticFacts.isEmpty {
            parts.append("## 语义事实\n" + semanticFacts.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Order-preserving deduplication helper for ContextMemory arrays.
private func contextMemoryDeduped(_ array: [String]) -> [String] {
    var seen = Set<String>()
    return array.filter { seen.insert($0).inserted }
}

// MARK: - ClaudeService Extension

extension ClaudeService {

    // MARK: - Constants

    /// Compression fires when input token usage exceeds this fraction of the context window.
    private static let compressionThreshold: Double = 0.75

    /// Number of most-recent messages to keep verbatim after compression.
    private static let recentMessageCount: Int = 6

    // MARK: - Public API

    /// Checks whether context usage is above the threshold and, if so, compresses the
    /// message history in-place using hierarchical memory extraction.
    /// Safe to call even when `currentInputTokens == 0`.
    func compressIfNeeded(
        messages: inout [MessageParameter.Message],
        memory: inout ContextMemory,
        service: any AnthropicService,
        modelId: String
    ) async {
        guard currentInputTokens > 0,
              contextUsageRatio > Self.compressionThreshold,
              messages.count > Self.recentMessageCount + 2 else { return }

        let cutoff = messages.count - Self.recentMessageCount
        let oldMessages = Array(messages[..<cutoff])
        let recentMessages = Array(messages[cutoff...])

        print("Context compression triggered: \(currentInputTokens) tokens (\(Int(contextUsageRatio * 100))%), compressing \(oldMessages.count) messages → hierarchical memory + \(recentMessages.count) recent")

        guard let extracted = await buildHierarchicalMemory(
            from: oldMessages,
            existing: memory,
            service: service,
            modelId: modelId
        ) else {
            print("Context compression: extraction failed, skipping")
            return
        }

        memory.merge(with: extracted)

        let memoryText = memory.toPromptText()
        messages = [
            MessageParameter.Message(
                role: .user,
                content: .text("【分层记忆摘要】以下是之前对话的结构化记忆，请在后续回复中保持这些上下文：\n\n\(memoryText)")
            ),
            MessageParameter.Message(
                role: .assistant,
                content: .text("已了解分层记忆摘要，将基于此上下文继续工作。")
            )
        ] + recentMessages

        currentInputTokens = 0
        print("Context compression complete: hierarchical memory injected + \(recentMessages.count) recent messages")
    }

    // MARK: - Private: Hierarchical Memory Extraction

    /// Codable mirror of the JSON schema requested from Claude.
    private struct MemoryJSON: Codable {
        var user_goal: String
        var completed_actions: [String]
        var pending_actions: [String]
        var key_files: [String]
        var failures_and_constraints: [String]
        var semantic_facts: [String]
    }

    private func buildHierarchicalMemory(
        from messages: [MessageParameter.Message],
        existing: ContextMemory,
        service: any AnthropicService,
        modelId: String
    ) async -> ContextMemory? {
        let transcript = messages.map { msg in
            let role = msg.role == "user" ? "用户" : "助手"
            let text = extractText(from: msg.content)
            return "[\(role)]: \(text)"
        }.joined(separator: "\n\n")

        let existingContext = existing.isEmpty ? "" : """

        已有的记忆摘要（请将新信息融合进去，不要重复已有条目）：
        \(existing.toPromptText())
        """

        let prompt = """
        分析以下对话历史，提取结构化的分层记忆。**只输出 JSON，不要包含任何其他文字、解释或代码块标记**。

        输出格式（严格 JSON，所有字段必须存在）：
        {
          "user_goal": "用户想要达成什么目标（一句话简述）",
          "completed_actions": ["已完成的具体操作，每条一项"],
          "pending_actions": ["尚未完成或仍在进行的操作，每条一项"],
          "key_files": ["提到的关键文件路径、函数名、模块名等，每条一项"],
          "failures_and_constraints": ["遇到的错误、失败、注意事项、限制条件，每条一项"],
          "semantic_facts": ["稳定的技术事实：项目结构、API约定、路径信息、已确认的设计决策等，每条一项"]
        }
        \(existingContext)

        对话历史：
        \(transcript)
        """

        let params = MessageParameter(
            model: .other(modelId),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 2048
        )

        do {
            let response = try await service.createMessage(params)
            let raw = response.content.compactMap { block -> String? in
                if case .text(let text, _) = block { return text }
                return nil
            }.joined()
            return parseMemoryJSON(raw)
        } catch {
            print("Context compression: extraction error: \(error)")
            return nil
        }
    }

    private func parseMemoryJSON(_ raw: String) -> ContextMemory? {
        // Strip optional markdown code fences (```json ... ```)
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n")
            text = lines.dropFirst().joined(separator: "\n")
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(MemoryJSON.self, from: data) else {
            print("Context compression: JSON parse failed, raw=\(raw.prefix(400))")
            return nil
        }

        var m = ContextMemory()
        m.userGoal = parsed.user_goal
        m.completedActions = parsed.completed_actions
        m.pendingActions = parsed.pending_actions
        m.keyFilesAndPaths = parsed.key_files
        m.failuresAndConstraints = parsed.failures_and_constraints
        m.semanticFacts = parsed.semantic_facts
        return m
    }

    // MARK: - Helpers

    /// Extracts a plain-text representation from a `MessageParameter.Message.Content` value.
    func extractText(from content: MessageParameter.Message.Content) -> String {
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
