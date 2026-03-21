import Foundation

enum WorkbenchNavigationItem: String, CaseIterable, Sendable {
    case sessions
    case workspace
    case git
    case lsp
    case skills
    case diagnostics

    static let defaultItem: WorkbenchNavigationItem = .sessions

    init?(launchArgument: String) {
        switch launchArgument {
        case "chat", "sessions":
            self = .sessions
        case "workspace":
            self = .workspace
        case "git":
            self = .git
        case "lsp":
            self = .lsp
        case "skills":
            self = .skills
        case "reliability", "diagnostics":
            self = .diagnostics
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .sessions:
            return "会话"
        case .workspace:
            return "工作区"
        case .git:
            return "Git"
        case .lsp:
            return "LSP"
        case .skills:
            return "技能"
        case .diagnostics:
            return "诊断"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions:
            return "bubble.left.and.bubble.right"
        case .workspace:
            return "folder"
        case .git:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .lsp:
            return "server.rack"
        case .skills:
            return "wand.and.stars"
        case .diagnostics:
            return "cross.case"
        }
    }

    var accessibilityIdentifier: String {
        "workbench.tab.\(rawValue)"
    }
}