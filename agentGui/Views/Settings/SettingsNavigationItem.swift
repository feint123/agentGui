import Foundation

enum SettingsNavigationItem: String, CaseIterable, Identifiable {
    case connection
    case updates
    case channels
    case executors
    case tools
    case intelligence
    case background
    case memory
    case general

    static let defaultItem: SettingsNavigationItem = .connection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection:
            return "连接"
        case .updates:
            return "更新"
        case .channels:
            return "渠道"
        case .executors:
            return "执行器"
        case .tools:
            return "工具"
        case .intelligence:
            return "智能"
        case .background:
            return "后台任务"
        case .memory:
            return "记忆"
        case .general:
            return "通用"
        }
    }

    var symbolName: String {
        switch self {
        case .connection:
            return "network"
        case .updates:
            return "arrow.trianglehead.2.clockwise"
        case .channels:
            return "bubble.left.and.bubble.right"
        case .executors:
            return "bolt.horizontal.circle"
        case .tools:
            return "hammer"
        case .intelligence:
            return "sparkles"
        case .background:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .memory:
            return "brain"
        case .general:
            return "gearshape"
        }
    }
}