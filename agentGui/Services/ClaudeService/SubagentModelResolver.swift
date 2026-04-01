//
//  SubagentModelResolver.swift
//  agentGui
//
//  按三层优先级解析子代理实际使用的模型 ID：
//  1. overrideModelId（调用方显式指定，最高优先级）
//  2. modelPreference（代理定义 frontmatter 中的 model-preference）
//     - 与父代理同系列时，直接复用父代理 ID（family-match 优化）
//     - 不同系列时，使用对应默认 ID
//  3. .inherit → 直接返回父代理 ID
//
//  对应 Claude Code: src/utils/model/agent.ts → getAgentModel()
//

import Foundation

enum SubagentModelResolver {

    // MARK: - 默认模型 ID（各系列的最新稳定版本）

    /// 默认 haiku 模型 ID（快速、低成本，适合探索类子代理）
    static let defaultHaikuModelId  = "claude-haiku-4-5"

    /// 默认 sonnet 模型 ID（均衡，适合通用子代理）
    static let defaultSonnetModelId = "claude-sonnet-4-6"

    /// 默认 opus 模型 ID（高能力，适合验证/规划子代理）
    static let defaultOpusModelId   = "claude-opus-4-6"

    // MARK: - 核心解析函数

    /// 解析子代理使用的实际模型 ID。
    ///
    /// - Parameters:
    ///   - preference: 代理定义中的模型偏好（`model-preference` frontmatter 字段）
    ///   - parentModelId: 父代理当前使用的模型 ID（`inherit` 语义的基准）
    ///   - overrideModelId: 调用方在 `run_subagent` 工具参数中显式传入的模型 ID（可选）
    /// - Returns: 子代理 API 请求应使用的完整模型 ID 字符串
    static func resolve(
        preference: SubagentModelPreference,
        parentModelId: String,
        overrideModelId: String? = nil
    ) -> String {
        // 1. 调用方 override 最优先（空字符串视为未指定）
        if let override = overrideModelId, !override.isEmpty {
            return override
        }

        // 2. inherit：直接返回父代理模型
        guard preference != .inherit else {
            return parentModelId
        }

        // 3. family-match 优化：若父代理已属于目标系列，复用父代理 ID
        //    避免不必要的版本降级（e.g. 父代理 claude-sonnet-4-6，preference .sonnet
        //    不应降级到 defaultSonnetModelId="claude-sonnet-4-5"）
        if parentMatchesFamily(parentModelId, preference: preference) {
            return parentModelId
        }

        // 4. 映射到默认 ID
        switch preference {
        case .haiku:   return defaultHaikuModelId
        case .sonnet:  return defaultSonnetModelId
        case .opus:    return defaultOpusModelId
        case .inherit: return parentModelId   // unreachable（已在上面处理）
        }
    }

    // MARK: - Internal

    /// 检测 modelId 是否属于 preference 对应的模型系列。
    /// 仅检测字符串中是否包含系列关键词（不区分大小写）。
    private static func parentMatchesFamily(
        _ parentModelId: String,
        preference: SubagentModelPreference
    ) -> Bool {
        let lower = parentModelId.lowercased()
        switch preference {
        case .haiku:   return lower.contains("haiku")
        case .sonnet:  return lower.contains("sonnet")
        case .opus:    return lower.contains("opus")
        case .inherit: return true
        }
    }
}
