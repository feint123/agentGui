import Foundation

enum SettingsNavigationItem: String, CaseIterable, Identifiable {
    case connection
    case tools
    case intelligence
    case memory
    case general

    static let defaultItem: SettingsNavigationItem = .connection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection:
            return "连接"
        case .tools:
            return "工具"
        case .intelligence:
            return "智能"
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
        case .tools:
            return "hammer"
        case .intelligence:
            return "sparkles"
        case .memory:
            return "brain"
        case .general:
            return "gearshape"
        }
    }
}