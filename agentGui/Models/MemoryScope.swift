import Foundation

enum MemoryScope: Equatable, Codable, Sendable {
    case user
    case workspace(id: String)
    case project(id: String)
    case session(id: String)
    case thread(id: String)
    case workflowRun(id: String)

    var namespace: String {
        switch self {
        case .user:
            return "user"
        case let .workspace(id):
            return "workspace:\(id)"
        case let .project(id):
            return "project:\(id)"
        case let .session(id):
            return "session:\(id)"
        case let .thread(id):
            return "thread:\(id)"
        case let .workflowRun(id):
            return "workflow-run:\(id)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
    }

    private enum ScopeKind: String, Codable {
        case user
        case workspace
        case project
        case session
        case thread
        case workflowRun
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ScopeKind.self, forKey: .kind)

        switch kind {
        case .user:
            self = .user
        case .workspace:
            self = .workspace(id: try container.decode(String.self, forKey: .id))
        case .project:
            self = .project(id: try container.decode(String.self, forKey: .id))
        case .session:
            self = .session(id: try container.decode(String.self, forKey: .id))
        case .thread:
            self = .thread(id: try container.decode(String.self, forKey: .id))
        case .workflowRun:
            self = .workflowRun(id: try container.decode(String.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .user:
            try container.encode(ScopeKind.user, forKey: .kind)
        case let .workspace(id):
            try container.encode(ScopeKind.workspace, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .project(id):
            try container.encode(ScopeKind.project, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .session(id):
            try container.encode(ScopeKind.session, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .thread(id):
            try container.encode(ScopeKind.thread, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .workflowRun(id):
            try container.encode(ScopeKind.workflowRun, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}