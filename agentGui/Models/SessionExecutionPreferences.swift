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

    init(
        modelID: String? = nil,
        approvalMode: String? = nil
    ) {
        self.modelID = modelID?.trimmedNonEmpty
        self.approvalMode = approvalMode?.trimmedNonEmpty
    }
}

struct OpenCodeCLISessionPreferences: Codable, Equatable, Sendable {
    var modelID: String?
    var approvalMode: String?

    init(
        modelID: String? = nil,
        approvalMode: String? = nil
    ) {
        self.modelID = modelID?.trimmedNonEmpty
        self.approvalMode = approvalMode?.trimmedNonEmpty
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