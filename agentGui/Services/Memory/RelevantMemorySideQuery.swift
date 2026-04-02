import Foundation
import SwiftAnthropic

/// 向 Claude Haiku 发起非流式 side query，从 memory manifest 中选出与当前 query 最相关的记忆文件。
///
/// 对齐 Claude Code `selectRelevantMemories`（`findRelevantMemories.ts`）。
///
/// 关键安全保证：`parseResponse` 对返回的文件名做白名单校验（`validFilenames`），
/// 防止模型返回注入路径或不存在的文件名。
struct RelevantMemorySideQuery: Sendable {

    static let sideQueryModel = "claude-3-5-haiku-latest"
    static let maxSelected = 5
    static let maxTokens = 256

    // MARK: - System Prompt

    static let systemPrompt = """
    You are selecting memories that will be useful to the AI agent as it processes a user's query. \
    You will be given the user's query and a list of available memory files with their filenames and descriptions.

    Return a JSON object with a "selected_memories" array of filenames (up to \(maxSelected)) \
    that will clearly be useful for the query.
    - Only include memories you are certain will be helpful based on their name and description.
    - If unsure, do not include. Be selective.
    - If none are clearly useful, return {"selected_memories": []}.
    - If a list of recently-used tools is provided, do NOT select reference/usage docs for those tools \
      (the model is already using them). DO select memories containing warnings or known issues.
    - Respond ONLY with valid JSON. No explanation, no markdown fences.
    """

    // MARK: - Public API

    /// 执行 side query。失败（网络、超时、解析错误）时返回空数组，不抛出。
    ///
    /// - Parameters:
    ///   - query: 当前用户消息文本
    ///   - headers: 已扫描的 topic file 头部列表
    ///   - recentTools: 本轮已成功调用的工具名（防误召回工具 reference 文件）
    ///   - alreadySurfaced: 本 session 已注入过的文件路径（URL.path），传给 API 前预过滤
    ///   - service: Anthropic API service（从 ClaudeService 传入）
    func select(
        query: String,
        headers: [MemoryTopicHeader],
        recentTools: [String],
        alreadySurfaced: Set<String>,
        service: any AnthropicService
    ) async -> [MemoryTopicHeader] {
        // 预过滤已注入文件
        let candidates = headers.filter { !alreadySurfaced.contains($0.filePath.path) }
        guard !candidates.isEmpty else { return [] }

        let manifest = MemoryManifestFormatter().format(candidates)
        let userPrompt = Self.buildUserPrompt(
            query: query,
            manifest: manifest,
            recentTools: recentTools
        )

        let validFilenames = Set(candidates.map { $0.filename })
        let selectedFilenames: [String]
        do {
            let response = try await service.createMessage(
                MessageParameter(
                    model: .other(Self.sideQueryModel),
                    messages: [.init(role: .user, content: .text(userPrompt))],
                    maxTokens: Self.maxTokens,
                    system: .text(Self.systemPrompt)
                )
            )
            let text = response.content.compactMap { block -> String? in
                if case .text(let t, _) = block { return t }
                return nil
            }.joined()
            selectedFilenames = Self.parseResponse(text, validFilenames: validFilenames)
        } catch {
            return []
        }

        let byFilename = Dictionary(uniqueKeysWithValues: candidates.map { ($0.filename, $0) })
        return selectedFilenames
            .compactMap { byFilename[$0] }
            .prefix(Self.maxSelected)
            .map { $0 }
    }

    // MARK: - Testable Helpers

    /// `buildUserPrompt` 为 `static` 以便测试直接调用，无需实例化。
    static func buildUserPrompt(
        query: String,
        manifest: String,
        recentTools: [String]
    ) -> String {
        var parts = [
            "Query: \(query)",
            "",
            "Available memories:",
            manifest
        ]
        if !recentTools.isEmpty {
            parts.append("")
            parts.append("Recently used tools: \(recentTools.joined(separator: ", "))")
        }
        return parts.joined(separator: "\n")
    }

    /// 解析 JSON 响应，过滤非白名单文件名，最多返回 5 个。
    static func parseResponse(
        _ text: String,
        validFilenames: Set<String>
    ) -> [String] {
        struct Response: Decodable {
            var selected_memories: [String]
        }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            return []
        }
        return Array(
            parsed.selected_memories
                .filter { validFilenames.contains($0) }
                .prefix(maxSelected)
        )
    }
}
