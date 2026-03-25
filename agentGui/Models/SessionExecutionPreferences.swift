import Foundation

struct SessionExecutionPreferences: Codable, Equatable, Sendable {
    var builtInModelID: String?
    var builtInApprovalMode: String?
    var gitHubCopilotCLI: GitHubCopilotCLISessionPreferences
    var openCodeCLI: OpenCodeCLISessionPreferences
    var claudeAdapterCLI: ClaudeAdapterCLISessionPreferences

    init(
        builtInModelID: String? = nil,
        builtInApprovalMode: String? = nil,
        gitHubCopilotCLI: GitHubCopilotCLISessionPreferences = .init(),
        openCodeCLI: OpenCodeCLISessionPreferences = .init(),
        claudeAdapterCLI: ClaudeAdapterCLISessionPreferences = .init()
    ) {
        self.builtInModelID = builtInModelID?.trimmedNonEmpty
        self.builtInApprovalMode = builtInApprovalMode?.trimmedNonEmpty
        self.gitHubCopilotCLI = gitHubCopilotCLI
        self.openCodeCLI = openCodeCLI
        self.claudeAdapterCLI = claudeAdapterCLI
    }
}

struct GitHubCopilotCLISessionPreferences: Codable, Equatable, Sendable {
    var modelID: String?
    var approvalMode: String?
    var modeID: String?

    init(
        modelID: String? = nil,
        approvalMode: String? = nil,
        modeID: String? = nil
    ) {
        self.modelID = modelID?.trimmedNonEmpty
        self.approvalMode = approvalMode?.trimmedNonEmpty
        self.modeID = modeID?.trimmedNonEmpty
    }
}

struct OpenCodeCLISessionPreferences: Codable, Equatable, Sendable {
    var modelID: String?
    var approvalMode: String?
    var modeID: String?

    init(
        modelID: String? = nil,
        approvalMode: String? = nil,
        modeID: String? = nil
    ) {
        self.modelID = modelID?.trimmedNonEmpty
        self.approvalMode = approvalMode?.trimmedNonEmpty
        self.modeID = modeID?.trimmedNonEmpty
    }
}

extension SessionExecutionPreferences {
    mutating func applyACPModeSelection(providerID: ConversationExecutionProviderID, modeID: String) {
        let normalizedModeID = modeID.trimmedNonEmpty

        switch providerID {
        case .githubCopilotCLI:
            gitHubCopilotCLI.modeID = normalizedModeID
        case .openCodeCLI:
            openCodeCLI.modeID = normalizedModeID
        case .claudeAdapterCLI:
            claudeAdapterCLI.modeID = normalizedModeID
        case .builtInAgent:
            break
        }
    }

    mutating func applyACPConfigSelection(
        providerID: ConversationExecutionProviderID,
        configID: String,
        value: String,
        modelConfigID: String?,
        approvalsConfigID: String?
    ) {
        let normalizedConfigID = configID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedModelConfigID = modelConfigID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedApprovalsConfigID = approvalsConfigID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedValue = value.trimmedNonEmpty

        switch providerID {
        case .githubCopilotCLI:
            if normalizedConfigID == normalizedModelConfigID {
                gitHubCopilotCLI.modelID = normalizedValue
            } else if normalizedConfigID == normalizedApprovalsConfigID {
                gitHubCopilotCLI.approvalMode = normalizedValue
            }
        case .openCodeCLI:
            if normalizedConfigID == normalizedModelConfigID {
                openCodeCLI.modelID = normalizedValue
            } else if normalizedConfigID == normalizedApprovalsConfigID {
                openCodeCLI.approvalMode = normalizedValue
            }
        case .claudeAdapterCLI:
            if normalizedConfigID == normalizedModelConfigID {
                claudeAdapterCLI.modelID = normalizedValue
            } else if normalizedConfigID == normalizedApprovalsConfigID {
                claudeAdapterCLI.approvalMode = normalizedValue
            }
        case .builtInAgent:
            break
        }
    }
}

typealias ClaudeAdapterCLISessionPreferences = OpenCodeCLISessionPreferences

enum SessionExecutionPreferencesResolver {
    static func builtInModelID(for session: Session, settings: AppSettings) -> String {
        session.executionPreferences.builtInModelID?.trimmedNonEmpty ?? settings.selectedModel
    }

    static func builtInApprovalMode(for session: Session, settings: AppSettings) -> ToolApprovalMode {
        ToolApprovalMode.resolved(
            from: session.executionPreferences.builtInApprovalMode?.trimmedNonEmpty
                ?? settings.builtInDefaultApprovalMode
        )
    }

    static func gitHubCopilotCLIConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        settings.githubCopilotCLIConfiguration.applying(session.executionPreferences.gitHubCopilotCLI)
    }

    static func openCodeCLIConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        settings.openCodeCLIConfiguration.applying(session.executionPreferences.openCodeCLI)
    }

    static func claudeAdapterCLIConfiguration(for session: Session, settings: AppSettings) -> ACPCLIConfiguration {
        settings.claudeAdapterCLIConfiguration.applying(session.executionPreferences.claudeAdapterCLI)
    }
}

extension ACPCLIConfiguration {
    func applying(_ sessionPreferences: OpenCodeCLISessionPreferences) -> ACPCLIConfiguration {
        var configuration = self
        if let modelID = sessionPreferences.modelID?.trimmedNonEmpty {
            configuration.defaultModel = modelID
        }
        if let approvalMode = sessionPreferences.approvalMode?.trimmedNonEmpty {
            configuration.defaultApprovalMode = approvalMode
        }
        return configuration
    }
}

extension Session {
    var executionPreferences: SessionExecutionPreferences {
        get {
            guard let data = executionPreferencesJSON.data(using: .utf8),
                  let preferences = try? JSONDecoder().decode(SessionExecutionPreferences.self, from: data) else {
                return SessionExecutionPreferences()
            }
            return preferences
        }
        set {
            executionPreferencesJSON = (try? String(
                data: JSONEncoder().encode(newValue),
                encoding: .utf8
            )) ?? "{}"
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}