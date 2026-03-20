import Foundation

struct ExecutionOptionItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
}

enum GitHubCopilotCLIApprovalModeOption: String, CaseIterable, Codable, Sendable {
    case defaultApprovals = "default"
    case bypassApprovals = "never"

    var title: String {
        switch self {
        case .defaultApprovals:
            return "default approvals"
        case .bypassApprovals:
            return "bypass approvals"
        }
    }

    static func resolved(from rawValue: String) -> GitHubCopilotCLIApprovalModeOption {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case bypassApprovals.rawValue:
            return .bypassApprovals
        default:
            return .defaultApprovals
        }
    }
}

struct GitHubCopilotCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var customAgentName: String
    var defaultApprovalMode: String
    var useACPStdIO: Bool

    static let `default` = GitHubCopilotCLIConfiguration(
        executablePath: "copilot",
        defaultModel: "",
        customAgentName: "",
        defaultApprovalMode: "default",
        useACPStdIO: true
    )
}

extension GitHubCopilotCLIConfiguration {
    static let curatedModelOptions: [ExecutionOptionItem] = [
        ExecutionOptionItem(id: "gpt-5", title: "GPT-5"),
        ExecutionOptionItem(id: "gpt-5-mini", title: "GPT-5 Mini"),
        ExecutionOptionItem(id: "gpt-4.1", title: "GPT-4.1"),
        ExecutionOptionItem(id: "gpt-4.1-mini", title: "GPT-4.1 Mini"),
        ExecutionOptionItem(id: "o3", title: "o3"),
        ExecutionOptionItem(id: "o4-mini", title: "o4-mini")
    ]

    static func modelOptions(
        inheritingTitle: String? = nil,
        including currentSelection: String
    ) -> [ExecutionOptionItem] {
        var options: [ExecutionOptionItem] = []
        if let inheritingTitle {
            options.append(ExecutionOptionItem(id: "", title: inheritingTitle))
        }
        options.append(contentsOf: curatedModelOptions)

        guard let selected = currentSelection.nonEmptyValue,
              options.contains(where: { $0.id == selected }) == false else {
            return options
        }

        return options + [ExecutionOptionItem(id: selected, title: selected)]
    }

    var normalizedApprovalMode: GitHubCopilotCLIApprovalModeOption {
        GitHubCopilotCLIApprovalModeOption.resolved(from: defaultApprovalMode)
    }

    func applying(_ sessionPreferences: GitHubCopilotCLISessionPreferences) -> GitHubCopilotCLIConfiguration {
        var configuration = self
        if let modelID = sessionPreferences.modelID?.nonEmptyValue {
            configuration.defaultModel = modelID
        }
        if let approvalMode = sessionPreferences.approvalMode?.nonEmptyValue {
            configuration.defaultApprovalMode = GitHubCopilotCLIApprovalModeOption.resolved(from: approvalMode).rawValue
        }
        return configuration
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}