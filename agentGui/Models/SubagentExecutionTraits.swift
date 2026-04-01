import Foundation

/// 子代理使用的模型偏好。
/// - `inherit`：沿用父代理当前模型（默认）
/// - `haiku`：claude-haiku 系列（快速、低成本，适合探索）
/// - `sonnet`：claude-sonnet 系列（均衡）
/// - `opus`：claude-opus 系列（高能力，适合验证/执行）
enum SubagentModelPreference: String, Sendable, Codable, Equatable {
    case inherit
    case haiku
    case sonnet
    case opus
}

/// 子代理 thinking budget 偏好。
enum SubagentEffort: String, Sendable, Codable, Equatable {
    case low
    case medium
    case high
}
