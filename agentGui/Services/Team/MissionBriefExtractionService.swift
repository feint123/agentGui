import Foundation
import SwiftAnthropic

// MARK: - Result

struct MissionBriefExtractionResult: Sendable, Equatable {
    let objective: String
    let constraints: [String]
    let acceptanceCriteria: [String]
    let suggestedMode: AgentTeamMode
}

// MARK: - Protocol

protocol MissionBriefExtractionService: Sendable {
    func extract(from rawInput: String) async throws -> MissionBriefExtractionResult
}

// MARK: - Built-In Implementation

struct BuiltInMissionBriefExtractionService: MissionBriefExtractionService {

    let service: any AnthropicService
    let modelID: String

    func extract(from rawInput: String) async throws -> MissionBriefExtractionResult {
        let prompt = buildPrompt(rawInput: rawInput)
        let params = MessageParameter(
            model: .other(modelID),
            messages: [MessageParameter.Message(role: .user, content: .text(prompt))],
            maxTokens: 1024
        )
        let response = try await service.createMessage(params)
        let raw = response.content.compactMap { block -> String? in
            if case .text(let text, _) = block { return text }
            return nil
        }.joined()

        guard let result = Self.parseExtractionJSON(raw) else {
            // 降级：将 rawInput 整体作为 objective
            return MissionBriefExtractionResult(
                objective: rawInput.trimmingCharacters(in: .whitespacesAndNewlines),
                constraints: [],
                acceptanceCriteria: [],
                suggestedMode: .executionDelivery
            )
        }
        return result
    }

    // MARK: - Internal (exposed for testing)

    static func parseExtractionJSON(_ raw: String) -> MissionBriefExtractionResult? {
        guard let parsed = ModelResponseJSONExtractor.decodeIfPresent(ExtractionJSON.self, from: raw) else {
            return nil
        }
        let mode = AgentTeamMode(rawValue: parsed.suggestedMode) ?? .executionDelivery
        return MissionBriefExtractionResult(
            objective: parsed.objective,
            constraints: parsed.constraints,
            acceptanceCriteria: parsed.acceptanceCriteria,
            suggestedMode: mode
        )
    }

    // MARK: - Private

    private func buildPrompt(rawInput: String) -> String {
        """
        你是一个任务分析助手。分析下方任务描述，提取结构化 brief。**只输出 JSON，不要包含任何其他文字或代码块标记**。

        输出格式（严格 JSON，所有字段必须存在）：
        {
          "objective": "一句话描述任务核心目标",
          "constraints": ["约束1", "约束2"],
          "acceptanceCriteria": ["验收条件1", "验收条件2"],
          "suggestedMode": "executionDelivery"
        }

        `suggestedMode` 可选值：
        - "executionDelivery"：目标明确、需要实际交付物（代码修复、文档生成等）
        - "creativeExploration"：需要多角度创意探索（方案探索、头脑风暴等）
        - "researchAndSynthesis"：需要调研汇总（技术选型、文献综述等）

        约束说明：若任务描述中没有明确约束，`constraints` 请填空数组。验收条件同理。

        任务描述：
        \(rawInput)
        """
    }

    // MARK: - JSON Decodable

    private struct ExtractionJSON: Decodable {
        let objective: String
        let constraints: [String]
        let acceptanceCriteria: [String]
        let suggestedMode: String
    }
}
