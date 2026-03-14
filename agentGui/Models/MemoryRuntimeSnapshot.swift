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
    var evidenceAnchorCount: Int
    var lifecycleTier: MemoryLifecycleTier
    var admissionExplanationSummary: String
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
        evidenceAnchorCount: Int,
        lifecycleTier: MemoryLifecycleTier,
        admissionExplanationSummary: String,
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
        self.evidenceAnchorCount = evidenceAnchorCount
        self.lifecycleTier = lifecycleTier
        self.admissionExplanationSummary = admissionExplanationSummary
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
            evidenceAnchorCount: record.evidenceAnchors.count,
            lifecycleTier: record.lifecycleTier,
            admissionExplanationSummary: record.admissionExplanation?.reasons.joined(separator: "; ") ?? "",
            promptOrder: promptOrder,
            exclusionReason: exclusionReason
        )
    }

    enum CodingKeys: String, CodingKey {
        case recordID
        case title
        case summary
        case layer
        case kind
        case scope
        case domainProfile
        case verificationStatus
        case retentionPolicy
        case sourceLabel
        case tags
        case confidence
        case createdAt
        case updatedAt
        case lastAccessedAt
        case estimatedPromptChars
        case evidenceAnchorCount
        case lifecycleTier
        case admissionExplanationSummary
        case promptOrder
        case exclusionReason
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.recordID = try container.decode(String.self, forKey: .recordID)
        self.title = try container.decode(String.self, forKey: .title)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.layer = try container.decode(MemoryLayer.self, forKey: .layer)
        self.kind = try container.decode(MemoryKind.self, forKey: .kind)
        self.scope = try container.decode(MemoryScope.self, forKey: .scope)
        self.domainProfile = try container.decode(String.self, forKey: .domainProfile)
        self.verificationStatus = try container.decode(MemoryRecord.VerificationStatus.self, forKey: .verificationStatus)
        self.retentionPolicy = try container.decode(MemoryRecord.RetentionPolicy.self, forKey: .retentionPolicy)
        self.sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        self.tags = try container.decode([String].self, forKey: .tags)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        self.estimatedPromptChars = try container.decode(Int.self, forKey: .estimatedPromptChars)
        self.evidenceAnchorCount = try container.decodeIfPresent(Int.self, forKey: .evidenceAnchorCount) ?? 0
        self.lifecycleTier = try container.decodeIfPresent(MemoryLifecycleTier.self, forKey: .lifecycleTier) ?? .warm
        self.admissionExplanationSummary = try container.decodeIfPresent(String.self, forKey: .admissionExplanationSummary) ?? ""
        self.promptOrder = try container.decodeIfPresent(Int.self, forKey: .promptOrder)
        self.exclusionReason = try container.decodeIfPresent(MemoryRuntimeExclusionReason.self, forKey: .exclusionReason)
    }

    private static func describe(source: MemoryRecord.Source) -> String {
        switch source {
        case .tool(let name):
            return "tool:\(name)"
        case .taskMemory:
            return "taskMemory"
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
        evidenceAnchorCount: Int = 0,
        lifecycleTier: MemoryLifecycleTier = .warm,
        admissionExplanationSummary: String = "",
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
            evidenceAnchorCount: evidenceAnchorCount,
            lifecycleTier: lifecycleTier,
            admissionExplanationSummary: admissionExplanationSummary,
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
    var retrievalIntent: MemoryRetrievalIntent?
}

struct MemoryRuntimeSnapshotMetrics: Codable, Equatable, Sendable {
    var candidateCount: Int
    var selectedCount: Int
    var excludedCount: Int
    var totalEstimatedPromptChars: Int
    var workingSetCost: Int
    var countBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
    var estimatedCharBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]

    enum CodingKeys: String, CodingKey {
        case candidateCount
        case selectedCount
        case excludedCount
        case totalEstimatedPromptChars
        case workingSetCost
        case countBreakdowns
        case estimatedCharBreakdowns
    }

    init(
        candidateCount: Int,
        selectedCount: Int,
        excludedCount: Int,
        totalEstimatedPromptChars: Int,
        workingSetCost: Int,
        countBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]],
        estimatedCharBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
    ) {
        self.candidateCount = candidateCount
        self.selectedCount = selectedCount
        self.excludedCount = excludedCount
        self.totalEstimatedPromptChars = totalEstimatedPromptChars
        self.workingSetCost = workingSetCost
        self.countBreakdowns = countBreakdowns
        self.estimatedCharBreakdowns = estimatedCharBreakdowns
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.candidateCount = try container.decode(Int.self, forKey: .candidateCount)
        self.selectedCount = try container.decode(Int.self, forKey: .selectedCount)
        self.excludedCount = try container.decode(Int.self, forKey: .excludedCount)
        self.totalEstimatedPromptChars = try container.decode(Int.self, forKey: .totalEstimatedPromptChars)
        self.workingSetCost = try container.decodeIfPresent(Int.self, forKey: .workingSetCost) ?? 0
        self.countBreakdowns = try container.decode([MemoryRuntimeSnapshotMetricDimension: [String: Int]].self, forKey: .countBreakdowns)
        self.estimatedCharBreakdowns = try container.decode([MemoryRuntimeSnapshotMetricDimension: [String: Int]].self, forKey: .estimatedCharBreakdowns)
    }
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
    var bridgeExpansions: [MemoryBridgeEdge]
    var dereferenceCount: Int
    var epistemicState: EpistemicState
    var influenceTrace: MemoryInfluenceTrace
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
        bridgeExpansions: [MemoryBridgeEdge] = [],
        dereferenceCount: Int = 0,
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace(),
        retrievalIntent: MemoryRetrievalIntent? = nil,
        workingSetCost: Int = 0,
        renderedPrompt: String = "## 已验证事实\n- Fixture Record"
    ) -> MemoryRuntimeSnapshot {
        let selectedCount = selectedRecords.count
        let metrics = MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedCount,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars },
            workingSetCost: workingSetCost,
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
                selectedCountByLayer: selectedCountByLayer,
                retrievalIntent: retrievalIntent
            ),
            selectedRecords: selectedRecords,
            excludedRecords: excludedRecords,
            bridgeExpansions: bridgeExpansions,
            dereferenceCount: dereferenceCount,
            epistemicState: epistemicState,
            influenceTrace: influenceTrace,
            renderedPrompt: renderedPrompt,
            metrics: metrics
        )
    }

    static func makeMetrics(
        candidateCount: Int,
        selectedRecords: [MemoryRuntimeSnapshotRecord],
        excludedRecords: [MemoryRuntimeSnapshotRecord],
        bridgeExpansionCount: Int = 0,
        dereferenceCount: Int = 0,
        includeWorkingSetCost: Bool = false
    ) -> MemoryRuntimeSnapshotMetrics {
        let totalEstimatedPromptChars = selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars }
        let workingSetCost: Int
        if includeWorkingSetCost {
            let tierWeightedChars = selectedRecords.reduce(0) { partial, record in
                partial + (record.estimatedPromptChars * tierWeight(for: record.lifecycleTier))
            }
            workingSetCost = tierWeightedChars + (bridgeExpansionCount * 24) + (dereferenceCount * 16)
        } else {
            workingSetCost = 0
        }

        return MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedRecords.count,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: totalEstimatedPromptChars,
            workingSetCost: workingSetCost,
            countBreakdowns: makeBreakdowns(records: selectedRecords, value: { _ in 1 }),
            estimatedCharBreakdowns: makeBreakdowns(records: selectedRecords, value: { $0.estimatedPromptChars })
        )
    }

    private static func tierWeight(for tier: MemoryLifecycleTier) -> Int {
        switch tier {
        case .hot:
            return 3
        case .warm:
            return 2
        case .cold, .archive:
            return 1
        }
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