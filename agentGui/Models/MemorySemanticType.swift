import Foundation

/// 对齐 Claude Code `memoryTypes.ts` 的四类型语义分类。
///
/// 这四个类型捕捉那些**无法从当前项目状态推导**出来的上下文：
/// 代码模式、架构、git 历史、文件结构等可随时 grep/read 得到的内容
/// 不应保存为记忆。
///
/// 每个 case 的完整 prompt 指导（when_to_save / how_to_use /
/// body_structure / examples）由 `MemoryTypeGuidanceComposer` 生成。
enum MemorySemanticType: String, Codable, Equatable, Sendable, CaseIterable {
    /// 用户身份、偏好、专业背景。始终私有。
    case user

    /// 用户给出的行为纠正或确认。记录失败 AND 成功。
    case feedback

    /// 项目进展、目标、决策、deadline、事故。偏向团队共享。
    case project

    /// 指向外部系统的引用（Linear/Grafana/Slack 等）。
    case reference
}
