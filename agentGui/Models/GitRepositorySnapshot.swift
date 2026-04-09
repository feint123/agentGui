import Foundation

enum GitChangeSection: String, Codable, Equatable {
    case staged
    case modified
    case untracked

    /// hover 时行尾主操作按钮使用的 SF Symbol 名称。
    /// staged → 取消暂存（minus.circle）; modified/untracked → 暂存（plus.circle）
    var hoverActionSymbol: String {
        switch self {
        case .staged:    return "minus.circle"
        case .modified:  return "plus.circle"
        case .untracked: return "plus.circle"
        }
    }
}

enum GitChangeStatus: String, Codable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked

    /// 非 hover 状态下行尾显示的短标识（参照 IDEA GitStageTree 节点图标文字）。
    var statusBadgeText: String {
        switch self {
        case .added:     return "A"
        case .modified:  return "M"
        case .deleted:   return "D"
        case .renamed:   return "R"
        case .untracked: return "??"
        }
    }
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { relativePath + ":" + status.rawValue + ":" + section.rawValue }
    let relativePath: String
    let absoluteURL: URL
    let status: GitChangeStatus
    let section: GitChangeSection
}

struct GitBranchReference: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
}

struct GitRepositorySnapshot: Equatable {
    let repositoryRoot: URL
    let repositoryName: String
    let branchName: String
    let hasRemoteTrackingBranch: Bool
    let aheadCount: Int
    let behindCount: Int
    let stagedChanges: [GitFileChange]
    let unstagedChanges: [GitFileChange]
    let untrackedChanges: [GitFileChange]
}
