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

    init(
        builtIn: BuiltInSessionExecutionPreferences = .init(),
        externalACP: [UUID: ACPRemoteSessionPreferenceSnapshot] = [:]
    ) {
        self.builtIn = builtIn
        self.externalACP = externalACP
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
}

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
            externalACP: externalACP ?? [:]
        )
    }

    enum CodingKeys: String, CodingKey {
        case builtIn
        case externalACP
        case builtInModelID
        case builtInApprovalMode
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(builtIn, forKey: .builtIn)
        try container.encode(externalACP, forKey: .externalACP)
        try container.encodeIfPresent(builtIn.modelID, forKey: .builtInModelID)
        try container.encodeIfPresent(builtIn.approvalMode, forKey: .builtInApprovalMode)
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