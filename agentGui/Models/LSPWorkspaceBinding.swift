import Foundation

struct LSPWorkspaceBinding: Codable, Hashable, Sendable {
    let workspaceRoot: String
    let serverID: String
    let languageID: String?
    let isManual: Bool
}
