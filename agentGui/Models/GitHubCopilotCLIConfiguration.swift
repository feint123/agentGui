import Foundation

struct ExecutionOptionItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let isEnabled: Bool

    init(id: String, title: String, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }
}

typealias GitHubCopilotCLIConfiguration = ACPCLIConfiguration

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

struct ACPCLIConfiguration: Codable, Equatable, Sendable {
    var executablePath: String
    var defaultModel: String
    var defaultApprovalMode: String

    init(
        executablePath: String,
        defaultModel: String,
        defaultApprovalMode: String
    ) {
        self.executablePath = executablePath
        self.defaultModel = defaultModel
        self.defaultApprovalMode = defaultApprovalMode
    }

    init(
        executablePath: String,
        defaultModel: String,
        customAgentName: String,
        defaultApprovalMode: String,
        useACPStdIO: Bool
    ) {
        _ = customAgentName
        _ = useACPStdIO
        self.init(
            executablePath: executablePath,
            defaultModel: defaultModel,
            defaultApprovalMode: defaultApprovalMode
        )
    }

    init(
        executablePath: String,
        defaultModel: String,
        defaultApprovalMode: String,
        environment: [String: String],
        useACPStdIO: Bool
    ) {
        _ = environment
        _ = useACPStdIO
        self.init(
            executablePath: executablePath,
            defaultModel: defaultModel,
            defaultApprovalMode: defaultApprovalMode
        )
    }
}

extension ACPCLIConfiguration {
    static let externalProviderDefaultApprovalMode = GitHubCopilotCLIApprovalModeOption.defaultApprovals.rawValue

    static let githubCopilotDefault = ACPCLIConfiguration(
        executablePath: "copilot",
        defaultModel: "",
        defaultApprovalMode: externalProviderDefaultApprovalMode
    )

    static let openCodeDefault = ACPCLIConfiguration(
        executablePath: "opencode",
        defaultModel: "",
        defaultApprovalMode: externalProviderDefaultApprovalMode
    )

    static let claudeAdapterDefault = ACPCLIConfiguration(
        executablePath: "claude-agent-acp",
        defaultModel: "",
        defaultApprovalMode: externalProviderDefaultApprovalMode
    )
}

extension ACPCLIConfiguration {
    static let curatedModelOptions: [ExecutionOptionItem] = [
        ExecutionOptionItem(id: "gpt-4.1", title: "GPT-4.1"),
        ExecutionOptionItem(id: "gpt-5-mini", title: "GPT-5 mini"),
        ExecutionOptionItem(id: "gpt-5.1", title: "GPT-5.1"),
        ExecutionOptionItem(id: "gpt-5.1-codex", title: "GPT-5.1-Codex"),
        ExecutionOptionItem(id: "gpt-5.1-codex-mini", title: "GPT-5.1-Codex-Mini"),
        ExecutionOptionItem(id: "gpt-5.1-codex-max", title: "GPT-5.1-Codex-Max"),
        ExecutionOptionItem(id: "gpt-5.2", title: "GPT-5.2"),
        ExecutionOptionItem(id: "gpt-5.2-codex", title: "GPT-5.2-Codex"),
        ExecutionOptionItem(id: "gpt-5.3-codex", title: "GPT-5.3-Codex"),
        ExecutionOptionItem(id: "gpt-5.4", title: "GPT-5.4"),
        ExecutionOptionItem(id: "gpt-5.4-mini", title: "GPT-5.4 mini"),
        ExecutionOptionItem(id: "claude-haiku-4-5", title: "Claude Haiku 4.5"),
        ExecutionOptionItem(id: "claude-opus-4-5", title: "Claude Opus 4.5"),
        ExecutionOptionItem(id: "claude-opus-4-6", title: "Claude Opus 4.6"),
        ExecutionOptionItem(id: "claude-opus-4-6-fast", title: "Claude Opus 4.6 (fast mode)"),
        ExecutionOptionItem(id: "claude-sonnet-4", title: "Claude Sonnet 4"),
        ExecutionOptionItem(id: "claude-sonnet-4-5", title: "Claude Sonnet 4.5"),
        ExecutionOptionItem(id: "claude-sonnet-4-6", title: "Claude Sonnet 4.6"),
        ExecutionOptionItem(id: "gemini-2.5-pro", title: "Gemini 2.5 Pro"),
        ExecutionOptionItem(id: "gemini-3-flash", title: "Gemini 3 Flash"),
        ExecutionOptionItem(id: "gemini-3-pro", title: "Gemini 3 Pro"),
        ExecutionOptionItem(id: "gemini-3.1-pro", title: "Gemini 3.1 Pro"),
        ExecutionOptionItem(id: "grok-code-fast-1", title: "Grok Code Fast 1"),
        ExecutionOptionItem(id: "raptor-mini", title: "Raptor mini"),
        ExecutionOptionItem(id: "goldeneye", title: "Goldeneye")
    ]

    static func copilotModelOptions(
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

    var sanitizedForGlobalSettings: ACPCLIConfiguration {
        var configuration = self
        configuration.defaultApprovalMode = Self.externalProviderDefaultApprovalMode
        return configuration
    }

    func applying(_ sessionPreferences: GitHubCopilotCLISessionPreferences) -> ACPCLIConfiguration {
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