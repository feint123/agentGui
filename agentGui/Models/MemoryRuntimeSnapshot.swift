import Foundation

enum MemoryRuntimeExclusionReason: String, Codable, Equatable, Sendable {
    case layerNotPlanned
    case archived
    case budgetTrimmed
    case rankedOut
    case duplicateOrSuperseded
    case other
}

enum MemoryRuntimeSnapshotMetricDimension: String, Codable, Hashable, Sendable {
    case layer
    case kind
    case scope
    case verificationStatus
    case source
}

struct MemoryRuntimeSnapshotRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String { recordID }

    var recordID: String
    var title: String
    var summary: String
    var layer: MemoryLayer
    var kind: MemoryKind
    var scope: MemoryScope
    var domainProfile: String
    var verificationStatus: MemoryRecord.VerificationStatus
    var retentionPolicy: MemoryRecord.RetentionPolicy
    var sourceLabel: String
    var tags: [String]
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var estimatedPromptChars: Int
    var promptOrder: Int?
    var exclusionReason: MemoryRuntimeExclusionReason?

    init(
        recordID: String,
        title: String,
        summary: String,
        layer: MemoryLayer,
        kind: MemoryKind,
        scope: MemoryScope,
        domainProfile: String,
        verificationStatus: MemoryRecord.VerificationStatus,
        retentionPolicy: MemoryRecord.RetentionPolicy,
        sourceLabel: String,
        tags: [String],
        confidence: Double,
        createdAt: Date,
        updatedAt: Date,
        lastAccessedAt: Date?,
        estimatedPromptChars: Int,
        promptOrder: Int? = nil,
        exclusionReason: MemoryRuntimeExclusionReason? = nil
    ) {
        self.recordID = recordID
        self.title = title
        self.summary = summary
        self.layer = layer
        self.kind = kind
        self.scope = scope
        self.domainProfile = domainProfile
        self.verificationStatus = verificationStatus
        self.retentionPolicy = retentionPolicy
        self.sourceLabel = sourceLabel
        self.tags = tags
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.estimatedPromptChars = estimatedPromptChars
        self.promptOrder = promptOrder
        self.exclusionReason = exclusionReason
    }

    init(record: MemoryRecord, promptOrder: Int? = nil, exclusionReason: MemoryRuntimeExclusionReason? = nil) {
        self.init(
            recordID: record.id,
            title: record.title,
            summary: record.summary,
            layer: record.layer,
            kind: record.kind,
            scope: record.scope,
            domainProfile: record.domainProfile,
            verificationStatus: record.verificationStatus,
            retentionPolicy: record.retentionPolicy,
            sourceLabel: Self.describe(source: record.source),
            tags: record.tags,
            confidence: record.confidence,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            lastAccessedAt: record.lastAccessedAt,
            estimatedPromptChars: Self.estimatePromptChars(title: record.title, summary: record.summary),
            promptOrder: promptOrder,
            exclusionReason: exclusionReason
        )
    }

    private static func describe(source: MemoryRecord.Source) -> String {
        switch source {
        case .tool(let name):
            return "tool:\(name)"
        case .taskMemory:
            return "taskMemory"
        case .storyMemory:
            return "storyMemory"
        case .userInput:
            return "userInput"
        case .system(let name):
            return "system:\(name)"
        }
    }

    private static func estimatePromptChars(title: String, summary: String) -> Int {
        let joined = summary.isEmpty ? title : "\(title)：\(summary)"
        return joined.count
    }
}

extension MemoryRuntimeSnapshotRecord {
    static func fixture(
        recordID: String = UUID().uuidString,
        title: String = "Fixture Record",
        summary: String = "Fixture summary",
        layer: MemoryLayer = .task,
        kind: MemoryKind = .working,
        scope: MemoryScope = .session(id: "s1"),
        domainProfile: String = "coding-task",
        verificationStatus: MemoryRecord.VerificationStatus = .verified,
        retentionPolicy: MemoryRecord.RetentionPolicy = .sessionBound,
        sourceLabel: String = "taskMemory",
        tags: [String] = [],
        confidence: Double = 1.0,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lastAccessedAt: Date? = nil,
        estimatedPromptChars: Int = 24,
        promptOrder: Int? = nil,
        exclusionReason: MemoryRuntimeExclusionReason? = nil
    ) -> MemoryRuntimeSnapshotRecord {
        MemoryRuntimeSnapshotRecord(
            recordID: recordID,
            title: title,
            summary: summary,
            layer: layer,
            kind: kind,
            scope: scope,
            domainProfile: domainProfile,
            verificationStatus: verificationStatus,
            retentionPolicy: retentionPolicy,
            sourceLabel: sourceLabel,
            tags: tags,
            confidence: confidence,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAccessedAt: lastAccessedAt,
            estimatedPromptChars: estimatedPromptChars,
            promptOrder: promptOrder,
            exclusionReason: exclusionReason
        )
    }
}

struct MemoryRuntimeSnapshotRequestSummary: Codable, Equatable, Sendable {
    var sessionId: String
    var threadId: String
    var workflowRunId: String?
    var taskKind: MemoryTaskKind
    var projectId: String?
    var workspaceRoot: String?
    var contextBudget: Int
    var userRequest: String
}

struct MemoryRuntimeSnapshotPlanSummary: Codable, Equatable, Sendable {
    var profileIDs: [String]
    var orderedLayers: [MemoryLayer]
    var itemBudgetByLayer: [MemoryLayer: Int]
    var candidateScopes: [String]
    var candidateCountByLayer: [MemoryLayer: Int]
    var selectedCountByLayer: [MemoryLayer: Int]
}

struct MemoryRuntimeSnapshotMetrics: Codable, Equatable, Sendable {
    var candidateCount: Int
    var selectedCount: Int
    var excludedCount: Int
    var totalEstimatedPromptChars: Int
    var countBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
    var estimatedCharBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
}

struct MemoryRuntimeSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sessionId: String
    var threadId: String
    var workflowRunId: String?
    var toolCallId: String?
    var agentRoundId: UUID?
    var createdAt: Date
    var request: MemoryRuntimeSnapshotRequestSummary
    var plan: MemoryRuntimeSnapshotPlanSummary
    var selectedRecords: [MemoryRuntimeSnapshotRecord]
    var excludedRecords: [MemoryRuntimeSnapshotRecord]
    var renderedPrompt: String
    var metrics: MemoryRuntimeSnapshotMetrics
}

extension MemoryRuntimeSnapshot {
    static func fixture(
        id: String = UUID().uuidString,
        sessionId: String = "s1",
        threadId: String = "t1",
        workflowRunId: String? = nil,
        toolCallId: String? = nil,
        agentRoundId: UUID? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        taskKind: MemoryTaskKind = .coding,
        projectId: String? = nil,
        workspaceRoot: String? = "/tmp/repo",
        contextBudget: Int = 4000,
        userRequest: String = "Fix build",
        profileIDs: [String] = ["coding-task"],
        orderedLayers: [MemoryLayer] = [.working, .task, .semantic, .episodic, .proceduralArchive],
        itemBudgetByLayer: [MemoryLayer: Int] = [.task: 1],
        candidateScopes: [String] = ["user", "session:s1", "thread:t1"],
        candidateCountByLayer: [MemoryLayer: Int] = [.task: 1],
        selectedCountByLayer: [MemoryLayer: Int] = [.task: 1],
        candidateCount: Int = 1,
        selectedRecords: [MemoryRuntimeSnapshotRecord] = [.fixture()],
        excludedRecords: [MemoryRuntimeSnapshotRecord] = [],
        renderedPrompt: String = "## 已验证事实\n- Fixture Record"
    ) -> MemoryRuntimeSnapshot {
        let selectedCount = selectedRecords.count
        let metrics = MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedCount,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars },
            countBreakdowns: makeBreakdowns(records: selectedRecords, value: { _ in 1 }),
            estimatedCharBreakdowns: makeBreakdowns(records: selectedRecords, value: { $0.estimatedPromptChars })
        )

        return MemoryRuntimeSnapshot(
            id: id,
            sessionId: sessionId,
            threadId: threadId,
            workflowRunId: workflowRunId,
            toolCallId: toolCallId,
            agentRoundId: agentRoundId,
            createdAt: createdAt,
            request: MemoryRuntimeSnapshotRequestSummary(
                sessionId: sessionId,
                threadId: threadId,
                workflowRunId: workflowRunId,
                taskKind: taskKind,
                projectId: projectId,
                workspaceRoot: workspaceRoot,
                contextBudget: contextBudget,
                userRequest: userRequest
            ),
            plan: MemoryRuntimeSnapshotPlanSummary(
                profileIDs: profileIDs,
                orderedLayers: orderedLayers,
                itemBudgetByLayer: itemBudgetByLayer,
                candidateScopes: candidateScopes,
                candidateCountByLayer: candidateCountByLayer,
                selectedCountByLayer: selectedCountByLayer
            ),
            selectedRecords: selectedRecords,
            excludedRecords: excludedRecords,
            renderedPrompt: renderedPrompt,
            metrics: metrics
        )
    }

    static func makeMetrics(
        candidateCount: Int,
        selectedRecords: [MemoryRuntimeSnapshotRecord],
        excludedRecords: [MemoryRuntimeSnapshotRecord]
    ) -> MemoryRuntimeSnapshotMetrics {
        MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedRecords.count,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars },
            countBreakdowns: makeBreakdowns(records: selectedRecords, value: { _ in 1 }),
            estimatedCharBreakdowns: makeBreakdowns(records: selectedRecords, value: { $0.estimatedPromptChars })
        )
    }

    private static func makeBreakdowns(
        records: [MemoryRuntimeSnapshotRecord],
        value: (MemoryRuntimeSnapshotRecord) -> Int
    ) -> [MemoryRuntimeSnapshotMetricDimension: [String: Int]] {
        let dimensions: [(MemoryRuntimeSnapshotMetricDimension, (MemoryRuntimeSnapshotRecord) -> String)] = [
            (.layer, { $0.layer.rawValue }),
            (.kind, { $0.kind.rawValue }),
            (.scope, { $0.scope.namespace }),
            (.verificationStatus, { $0.verificationStatus.rawValue }),
            (.source, { $0.sourceLabel })
        ]

        var result: [MemoryRuntimeSnapshotMetricDimension: [String: Int]] = [:]
        for (dimension, label) in dimensions {
            var grouped: [String: Int] = [:]
            for record in records {
                grouped[label(record), default: 0] += value(record)
            }
            result[dimension] = grouped
        }
        return result
    }
}