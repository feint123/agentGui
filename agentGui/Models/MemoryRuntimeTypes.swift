import Foundation

enum MemoryTaskKind: String, Codable, Equatable, Hashable, Sendable {
    case creativeWriting
    case coding
    case generalAssistant
}

protocol MemoryDomainProfiling {
    var id: String { get }
    var version: Int { get }
    var supportedTaskKinds: Set<MemoryTaskKind> { get }
    func writePolicy(for request: MemoryRuntimeRequest) -> MemoryWritePolicy
    func consolidationRules() -> [MemoryConsolidationRule]
}

struct MemoryDomainProfile: Equatable, Sendable, MemoryDomainProfiling {
    var id: String
    var version: Int
    var supportedTaskKinds: Set<MemoryTaskKind>
    var defaultWritePolicy: MemoryWritePolicy
    var rules: [MemoryConsolidationRule]

    init(
        id: String,
        version: Int = 1,
        supportedTaskKinds: Set<MemoryTaskKind>,
        defaultWritePolicy: MemoryWritePolicy = .readMostly,
        rules: [MemoryConsolidationRule] = []
    ) {
        self.id = id
        self.version = version
        self.supportedTaskKinds = supportedTaskKinds
        self.defaultWritePolicy = defaultWritePolicy
        self.rules = rules
    }

    static func creativeWriting() -> MemoryDomainProfile {
        MemoryDomainProfile(
            id: "creative-writing",
            supportedTaskKinds: [.creativeWriting],
            defaultWritePolicy: .readMostly,
            rules: [
                MemoryConsolidationRule(
                    id: "creative-episodic-events",
                    sourceLayers: [.episodic, .working],
                    targetLayer: .episodic,
                    targetKind: .episodic,
                    requiresVerified: true,
                    minimumConfidence: 0.7
                ),
                MemoryConsolidationRule(
                    id: "creative-semantic-canon",
                    sourceLayers: [.semantic],
                    targetLayer: .semantic,
                    targetKind: .semantic,
                    requiresVerified: true,
                    minimumConfidence: 0.9
                )
            ]
        )
    }

    static func codingTask() -> MemoryDomainProfile {
        MemoryDomainProfile(
            id: "coding-task",
            supportedTaskKinds: [.coding],
            defaultWritePolicy: .readMostly,
            rules: [
                MemoryConsolidationRule(
                    id: "coding-verified-fact",
                    sourceLayers: [.working, .task],
                    targetLayer: .task,
                    targetKind: .working,
                    requiresVerified: true,
                    minimumConfidence: 0.7
                ),
                MemoryConsolidationRule(
                    id: "coding-failure-chain",
                    sourceLayers: [.task],
                    targetLayer: .episodic,
                    targetKind: .episodic,
                    minimumConfidence: 0.0
                ),
                MemoryConsolidationRule(
                    id: "coding-stable-semantic-fact",
                    sourceLayers: [.task, .semantic],
                    targetLayer: .semantic,
                    targetKind: .semantic,
                    requiresVerified: true,
                    minimumConfidence: 0.95
                )
            ]
        )
    }

    static func userPreferences() -> MemoryDomainProfile {
        MemoryDomainProfile(
            id: "user-preferences",
            supportedTaskKinds: [.creativeWriting, .coding, .generalAssistant],
            defaultWritePolicy: .readWrite,
            rules: []
        )
    }

    func writePolicy(for request: MemoryRuntimeRequest) -> MemoryWritePolicy {
        _ = request
        return defaultWritePolicy
    }

    func consolidationRules() -> [MemoryConsolidationRule] {
        rules
    }
}

struct MemoryRuntimeRequest: Equatable, Sendable {
    var sessionId: String
    var threadId: String
    var workflowRunId: String?
    var userRequest: String
    var taskKind: MemoryTaskKind
    var projectId: String?
    var workspaceRoot: String?
    var contextBudget: Int

    init(
        sessionId: String,
        threadId: String,
        workflowRunId: String?,
        userRequest: String,
        taskKind: MemoryTaskKind,
        projectId: String?,
        workspaceRoot: String?,
        contextBudget: Int
    ) {
        self.sessionId = sessionId
        self.threadId = threadId
        self.workflowRunId = workflowRunId
        self.userRequest = userRequest
        self.taskKind = taskKind
        self.projectId = projectId
        self.workspaceRoot = workspaceRoot
        self.contextBudget = contextBudget
    }
}

struct MemoryRuntimeFeatureConfiguration: Equatable, Sendable {
    var enableAdmissionV2: Bool
    var enableGoalConditionedRetrieval: Bool
    var enableBridgeExpansion: Bool
    var enableLifecycleManager: Bool
    var enableExperienceDistillation: Bool

    init(
        enableAdmissionV2: Bool = true,
        enableGoalConditionedRetrieval: Bool = true,
        enableBridgeExpansion: Bool = true,
        enableLifecycleManager: Bool = true,
        enableExperienceDistillation: Bool = true
    ) {
        self.enableAdmissionV2 = enableAdmissionV2
        self.enableGoalConditionedRetrieval = enableGoalConditionedRetrieval
        self.enableBridgeExpansion = enableBridgeExpansion
        self.enableLifecycleManager = enableLifecycleManager
        self.enableExperienceDistillation = enableExperienceDistillation
    }

    static let allEnabled = MemoryRuntimeFeatureConfiguration()
}

extension MemoryRuntimeFeatureConfiguration {
    init(settings: AppSettings) {
        self.init(
            enableAdmissionV2: settings.enableEpistemicExtraction,
            enableGoalConditionedRetrieval: settings.enableRMSRetrieval,
            enableBridgeExpansion: settings.enableBridgeExpansion,
            enableLifecycleManager: !settings.enableLegacyMemoryCompatibility,
            enableExperienceDistillation: settings.enableRMSDistillation
        )
    }
}

struct MemoryRuntimeContext: Equatable, Sendable {
    var profiles: [String]
    var records: [MemoryRecord]
    var writePolicy: MemoryWritePolicy
    var warnings: [String]
    var epistemicState: EpistemicState
    var influenceTrace: MemoryInfluenceTrace
    var renderedPrompt: String
    var runtimeSnapshot: MemoryRuntimeSnapshot?

    init(
        profiles: [String],
        records: [MemoryRecord],
        writePolicy: MemoryWritePolicy = .readMostly,
        warnings: [String] = [],
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace(),
        renderedPrompt: String = "",
        runtimeSnapshot: MemoryRuntimeSnapshot? = nil
    ) {
        self.profiles = profiles
        self.records = records
        self.writePolicy = writePolicy
        self.warnings = warnings
        self.epistemicState = epistemicState
        self.influenceTrace = influenceTrace
        self.renderedPrompt = renderedPrompt
        self.runtimeSnapshot = runtimeSnapshot
    }
}

enum MemoryWritePolicy: String, Codable, Equatable, Sendable {
    case readOnly
    case readMostly
    case readWrite
}

struct MemoryWriteRequest: Equatable, Sendable {
    var record: MemoryRecord
    var allowReplacement: Bool

    init(record: MemoryRecord, allowReplacement: Bool = true) {
        self.record = record
        self.allowReplacement = allowReplacement
    }
}

enum MemoryWriteAction: Equatable, Sendable {
    case inserted
    case updated
    case replaced(replacedRecordID: String)
    case archived(reason: MemoryArchiveReason)
}

struct MemoryWriteResult: Equatable, Sendable {
    var record: MemoryRecord
    var action: MemoryWriteAction

    init(record: MemoryRecord, action: MemoryWriteAction) {
        self.record = record
        self.action = action
    }
}

enum MemoryArchiveReason: String, Codable, Equatable, Sendable {
    case superseded
    case retentionExpired
    case governance
    case userRequested
}

enum MemoryStoreError: Error, Equatable, Sendable {
    case recordNotFound(String)
    case unsupportedOperation(String)
    case serializationFailed(String)
}

struct MemoryRetrievalPlan: Equatable, Sendable {
    var orderedLayers: [MemoryLayer]
    var itemBudgetByLayer: [MemoryLayer: Int]
    var objectBudgetByType: [MemoryRetrievalObjectType: Int]
    var profileIDs: [String]
    var includeArchived: Bool

    init(
        orderedLayers: [MemoryLayer],
        itemBudgetByLayer: [MemoryLayer: Int],
        objectBudgetByType: [MemoryRetrievalObjectType: Int] = [:],
        profileIDs: [String],
        includeArchived: Bool = false
    ) {
        self.orderedLayers = orderedLayers
        self.itemBudgetByLayer = itemBudgetByLayer
        self.objectBudgetByType = objectBudgetByType
        self.profileIDs = profileIDs
        self.includeArchived = includeArchived
    }
}