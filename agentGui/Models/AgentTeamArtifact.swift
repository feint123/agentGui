import Foundation

// MARK: - Kind

enum AgentTeamArtifactKind: String, Codable, Equatable, Sendable, CaseIterable {
    case brief
    case ideaDraft
    case explorationReport
    case implementationPlan
    case patchProposal
    case validationReport
    case reviewReport
    case finalSynthesis
}

// MARK: - Status

enum AgentTeamArtifactStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case draft
    case submitted
    case accepted
    case rejected
}

// MARK: - Payload

enum AgentTeamArtifactPayload: Codable, Equatable, Sendable {
    case text(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        switch type_ {
        case "text":
            let content = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(content)
        default:
            let content = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(content)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .text)
        }
    }

    var textContent: String {
        switch self {
        case let .text(content): return content
        }
    }
}

// MARK: - Artifact

struct AgentTeamArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: AgentTeamArtifactKind
    let title: String
    let producer: ExecutionProviderReference
    let taskCardID: UUID
    let version: Int
    let summary: String
    let payload: AgentTeamArtifactPayload
    var status: AgentTeamArtifactStatus
}

// MARK: - Board State

struct AgentTeamArtifactBoardState: Codable, Equatable, Sendable {
    var artifacts: [AgentTeamArtifact]

    init(artifacts: [AgentTeamArtifact] = []) {
        self.artifacts = artifacts
    }

    func artifacts(for taskCardID: UUID) -> [AgentTeamArtifact] {
        artifacts.filter { $0.taskCardID == taskCardID }
    }

    func artifacts(by producer: ExecutionProviderReference) -> [AgentTeamArtifact] {
        artifacts.filter { $0.producer == producer }
    }

    func artifact(id: UUID) -> AgentTeamArtifact? {
        artifacts.first { $0.id == id }
    }
}
