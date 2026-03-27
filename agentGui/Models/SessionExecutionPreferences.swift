import Foundation

struct BuiltInSessionExecutionPreferences: Codable, Equatable, Sendable {
    var modelID: String?
    var approvalMode: String?

    init(modelID: String? = nil, approvalMode: String? = nil) {
        self.modelID = modelID?.trimmedNonEmpty
        self.approvalMode = approvalMode?.trimmedNonEmpty
    }
}

struct ACPRemoteSessionPreferenceSnapshot: Codable, Equatable, Sendable {
    var selectedModeID: String?
    var selectedValuesByConfigID: [String: String]

    init(selectedModeID: String? = nil, selectedValuesByConfigID: [String: String] = [:]) {
        self.selectedModeID = selectedModeID?.trimmedNonEmpty
        self.selectedValuesByConfigID = selectedValuesByConfigID
    }
}

struct SessionExecutionPreferences: Codable, Equatable, Sendable {
    var builtIn: BuiltInSessionExecutionPreferences
    var externalACP: [UUID: ACPRemoteSessionPreferenceSnapshot]
    var gitHubCopilotCLI: GitHubCopilotCLISessionPreferences
    var openCodeCLI: OpenCodeCLISessionPreferences
    var claudeAdapterCLI: ClaudeAdapterCLISessionPreferences

    init(
        builtIn: BuiltInSessionExecutionPreferences = .init(),
        externalACP: [UUID: ACPRemoteSessionPreferenceSnapshot] = [:],
        gitHubCopilotCLI: GitHubCopilotCLISessionPreferences = .init(),
        openCodeCLI: OpenCodeCLISessionPreferences = .init(),
        claudeAdapterCLI: ClaudeAdapterCLISessionPreferences = .init()
    ) {
        self.builtIn = builtIn
        self.externalACP = externalACP
        self.gitHubCopilotCLI = gitHubCopilotCLI
        self.openCodeCLI = openCodeCLI
        self.claudeAdapterCLI = claudeAdapterCLI
    }
}

extension SessionExecutionPreferences {
    var builtInModelID: String? {
        get { builtIn.modelID }
        set { builtIn.modelID = newValue?.trimmedNonEmpty }
    }

    var builtInApprovalMode: String? {
        get { builtIn.approvalMode }
        set { builtIn.approvalMode = newValue?.trimmedNonEmpty }
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
    mutating func applyACPModeSelection(providerReference: ExecutionProviderReference, modeID: String) {
        switch providerReference {
        case .builtIn:
            break
        case let .externalACP(profileID):
            var snapshot = externalACP[profileID] ?? ACPRemoteSessionPreferenceSnapshot()
            snapshot.selectedModeID = modeID.trimmedNonEmpty
            externalACP[profileID] = snapshot
        }
    }

    mutating func applyACPModeSelection(providerID: ConversationExecutionProviderID, modeID: String) {
        let providerReference: ExecutionProviderReference = providerID == .builtInAgent
            ? .builtIn
            : LegacyExternalACPProviderKey.allCases.first(where: { $0.conversationExecutionProviderID == providerID })?.compatibilityReference ?? .builtIn
        applyACPModeSelection(providerReference: providerReference, modeID: modeID)

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
        providerReference: ExecutionProviderReference,
        configID: String,
        value: String,
        modelConfigID: String?,
        approvalsConfigID: String?
    ) {
        let normalizedConfigID = configID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedValue = value.trimmedNonEmpty

        switch providerReference {
        case .builtIn:
            break
        case let .externalACP(profileID):
            var snapshot = externalACP[profileID] ?? ACPRemoteSessionPreferenceSnapshot()
            if let normalizedValue {
                snapshot.selectedValuesByConfigID[normalizedConfigID] = normalizedValue
            } else {
                snapshot.selectedValuesByConfigID.removeValue(forKey: normalizedConfigID)
            }
            externalACP[profileID] = snapshot
        }
    }

    mutating func applyACPConfigSelection(
        providerID: ConversationExecutionProviderID,
        configID: String,
        value: String,
        modelConfigID: String?,
        approvalsConfigID: String?
    ) {
        let providerReference: ExecutionProviderReference = providerID == .builtInAgent
            ? .builtIn
            : LegacyExternalACPProviderKey.allCases.first(where: { $0.conversationExecutionProviderID == providerID })?.compatibilityReference ?? .builtIn
        applyACPConfigSelection(
            providerReference: providerReference,
            configID: configID,
            value: value,
            modelConfigID: modelConfigID,
            approvalsConfigID: approvalsConfigID
        )

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

extension SessionExecutionPreferences {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let builtIn = try container.decodeIfPresent(BuiltInSessionExecutionPreferences.self, forKey: .builtIn)
        let externalACP = try container.decodeIfPresent([UUID: ACPRemoteSessionPreferenceSnapshot].self, forKey: .externalACP)
        let builtInModelID = try container.decodeIfPresent(String.self, forKey: .builtInModelID)
        let builtInApprovalMode = try container.decodeIfPresent(String.self, forKey: .builtInApprovalMode)

        self.init(
            builtIn: builtIn ?? BuiltInSessionExecutionPreferences(
                modelID: builtInModelID,
                approvalMode: builtInApprovalMode
            ),
            externalACP: externalACP ?? [:],
            gitHubCopilotCLI: try container.decodeIfPresent(GitHubCopilotCLISessionPreferences.self, forKey: .gitHubCopilotCLI) ?? .init(),
            openCodeCLI: try container.decodeIfPresent(OpenCodeCLISessionPreferences.self, forKey: .openCodeCLI) ?? .init(),
            claudeAdapterCLI: try container.decodeIfPresent(ClaudeAdapterCLISessionPreferences.self, forKey: .claudeAdapterCLI) ?? .init()
        )
    }

    enum CodingKeys: String, CodingKey {
        case builtIn
        case externalACP
        case builtInModelID
        case builtInApprovalMode
        case gitHubCopilotCLI
        case openCodeCLI
        case claudeAdapterCLI
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(builtIn, forKey: .builtIn)
        try container.encode(externalACP, forKey: .externalACP)
        try container.encodeIfPresent(builtIn.modelID, forKey: .builtInModelID)
        try container.encodeIfPresent(builtIn.approvalMode, forKey: .builtInApprovalMode)
        try container.encode(gitHubCopilotCLI, forKey: .gitHubCopilotCLI)
        try container.encode(openCodeCLI, forKey: .openCodeCLI)
        try container.encode(claudeAdapterCLI, forKey: .claudeAdapterCLI)
    }

    func migrated(using legacyProfileIDs: [LegacyExternalACPProviderKey: UUID]) -> SessionExecutionPreferences {
        var migrated = self

        if let profileID = legacyProfileIDs[.githubCopilotCLI] {
            migrated.externalACP[profileID] = ACPRemoteSessionPreferenceSnapshot(
                selectedModeID: gitHubCopilotCLI.modeID,
                selectedValuesByConfigID: selectedValues(
                    modelID: gitHubCopilotCLI.modelID,
                    approvalMode: gitHubCopilotCLI.approvalMode
                )
            )
        }

        if let profileID = legacyProfileIDs[.openCodeCLI] {
            migrated.externalACP[profileID] = ACPRemoteSessionPreferenceSnapshot(
                selectedModeID: openCodeCLI.modeID,
                selectedValuesByConfigID: selectedValues(
                    modelID: openCodeCLI.modelID,
                    approvalMode: openCodeCLI.approvalMode
                )
            )
        }

        if let profileID = legacyProfileIDs[.claudeAdapterCLI] {
            migrated.externalACP[profileID] = ACPRemoteSessionPreferenceSnapshot(
                selectedModeID: claudeAdapterCLI.modeID,
                selectedValuesByConfigID: selectedValues(
                    modelID: claudeAdapterCLI.modelID,
                    approvalMode: claudeAdapterCLI.approvalMode
                )
            )
        }

        return migrated
    }

    private func selectedValues(modelID: String?, approvalMode: String?) -> [String: String] {
        var values: [String: String] = [:]
        if let modelID = modelID?.trimmedNonEmpty {
            values["legacy:model"] = modelID
        }
        if let approvalMode = approvalMode?.trimmedNonEmpty {
            values["legacy:approval_mode"] = approvalMode
        }
        return values
    }
}

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