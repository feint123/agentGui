import Foundation

enum GitChangeSection: String, Codable, Equatable {
    case staged
    case modified
    case untracked
}

enum GitChangeStatus: String, Codable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case untracked
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { relativePath + ":" + status.rawValue + ":" + section.rawValue }
    let relativePath: String
    let absoluteURL: URL
    let status: GitChangeStatus
    let section: GitChangeSection
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
