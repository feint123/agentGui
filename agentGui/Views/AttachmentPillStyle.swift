import SwiftUI

/// 附件 pill 的统一颜色 token。
/// 对标 VS Code OmittedState + Open WebUI colorClassName 模式。
enum AttachmentPillStyle {

    /// origin-based 基础色。
    static func originTint(for origin: AttachmentOrigin) -> Color {
        switch origin {
        case .project:  return .accentColor
        case .focused:  return .orange
        case .external: return .secondary
        }
    }

    /// 最终 pill 状态色（status 优先级高于 origin）。
    static func statusColor(origin: AttachmentOrigin, status: AttachmentStatus) -> Color {
        switch status {
        case .modified: return .yellow
        case .missing:  return .red
        case .valid:    return originTint(for: origin)
        }
    }

    /// Pill 背景 opacity（normal / hover）。
    static func backgroundOpacity(status: AttachmentStatus, hovered: Bool) -> Double {
        switch status {
        case .valid:    return hovered ? 0.12 : 0.07
        case .modified: return hovered ? 0.15 : 0.08
        case .missing:  return hovered ? 0.12 : 0.06
        }
    }

    /// Pill border opacity。
    static func borderOpacity(status: AttachmentStatus) -> Double {
        switch status {
        case .valid:    return 0.18
        case .modified: return 0.30
        case .missing:  return 0.25
        }
    }
}
