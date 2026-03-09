import Foundation

enum StoryProjectInspectorTab: String, CaseIterable, Identifiable {
    case overview
    case structure
    case characters
    case locations
    case rules
    case timeline
    case foreshadows
    case continuity
    case style

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            return "总览"
        case .structure:
            return "结构"
        case .characters:
            return "角色"
        case .locations:
            return "地点"
        case .rules:
            return "规则"
        case .timeline:
            return "时间线"
        case .foreshadows:
            return "伏笔"
        case .continuity:
            return "连续性"
        case .style:
            return "风格"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .structure:
            return "list.bullet.rectangle"
        case .characters:
            return "person.2"
        case .locations:
            return "map"
        case .rules:
            return "scroll"
        case .timeline:
            return "timeline.selection"
        case .foreshadows:
            return "lightbulb"
        case .continuity:
            return "exclamationmark.triangle"
        case .style:
            return "text.book.closed"
        }
    }
}