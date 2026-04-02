import Foundation

/// 四类记忆类型，对齐 Claude Code `memoryTypes.ts` 中的 `MEMORY_TYPES`。
///
/// - `user`: 用户角色/偏好/背景信息
/// - `feedback`: 用户给出的工作方式指导
/// - `project`: 项目工作状态/目标/决策
/// - `reference`: 外部系统信息指针
///
/// `parse(_:)` 对未知值静默返回 `nil`（对齐 Claude Code `parseMemoryType`，
/// 保证 legacy 文件降级兼容性）。
enum MemoryTopicType: String, CaseIterable, Sendable {
    case user
    case feedback
    case project
    case reference

    /// 从 frontmatter raw 字符串解析类型。
    /// - Parameter raw: `nil`、空字符串或未知字符串均返回 `nil`。
    static func parse(_ raw: String?) -> MemoryTopicType? {
        guard let raw, !raw.isEmpty else { return nil }
        return MemoryTopicType(rawValue: raw)
    }
}
