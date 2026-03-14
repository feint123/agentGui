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
        self.admissionExplanationSummary = try container.decodeIfPresent(String.self, forKey: .admissionExplanationSummary) ?? ""
        self.promptOrder = try container.decodeIfPresent(Int.self, forKey: .promptOrder)
        self.exclusionReason = try container.decodeIfPresent(MemoryRuntimeExclusionReason.self, forKey: .exclusionReason)
    }

    private static func describe(source: MemoryRecord.Source) -> String {
        switch source {
        case .tool(let name):
            return "tool:\(name)"
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
        sourceLabel: String = "system:tests",
        tags: [String] = [],
        confidence: Double = 1.0,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        lastAccessedAt: Date? = nil,
        estimatedPromptChars: Int = 24,
        evidenceAnchorCount: Int = 0,
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
    var postEnforcementPromptChars: Int
    var trimmedCharCount: Int
    var trimmedSectionIDs: [String]
    var workingSetCost: Int
    var countBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
    var estimatedCharBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]

    enum CodingKeys: String, CodingKey {
        case candidateCount
        case selectedCount
        case excludedCount
        case totalEstimatedPromptChars
        case postEnforcementPromptChars
        case trimmedCharCount
        case trimmedSectionIDs
        case workingSetCost
        case countBreakdowns
        case estimatedCharBreakdowns
    }

    init(
        candidateCount: Int,
        selectedCount: Int,
        excludedCount: Int,
        totalEstimatedPromptChars: Int,
        postEnforcementPromptChars: Int,
        trimmedCharCount: Int,
        trimmedSectionIDs: [String],
        workingSetCost: Int,
        countBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]],
        estimatedCharBreakdowns: [MemoryRuntimeSnapshotMetricDimension: [String: Int]]
    ) {
        self.candidateCount = candidateCount
        self.selectedCount = selectedCount
        self.excludedCount = excludedCount
        self.totalEstimatedPromptChars = totalEstimatedPromptChars
        self.postEnforcementPromptChars = postEnforcementPromptChars
        self.trimmedCharCount = trimmedCharCount
        self.trimmedSectionIDs = trimmedSectionIDs
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
        self.postEnforcementPromptChars = try container.decodeIfPresent(Int.self, forKey: .postEnforcementPromptChars) ?? self.totalEstimatedPromptChars
        self.trimmedCharCount = try container.decodeIfPresent(Int.self, forKey: .trimmedCharCount) ?? 0
        self.trimmedSectionIDs = try container.decodeIfPresent([String].self, forKey: .trimmedSectionIDs) ?? []
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
    var dereferenceCount: Int
    var warnings: [String]
    var epistemicState: EpistemicState
    var influenceTrace: MemoryInfluenceTrace
    var renderedPrompt: String
    var metrics: MemoryRuntimeSnapshotMetrics

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case threadId
        case workflowRunId
        case toolCallId
        case agentRoundId
        case createdAt
        case request
        case plan
        case selectedRecords
        case excludedRecords
        case dereferenceCount
        case warnings
        case epistemicState
        case influenceTrace
        case renderedPrompt
        case metrics
    }

    init(
        id: String,
        sessionId: String,
        threadId: String,
        workflowRunId: String?,
        toolCallId: String?,
        agentRoundId: UUID?,
        createdAt: Date,
        request: MemoryRuntimeSnapshotRequestSummary,
        plan: MemoryRuntimeSnapshotPlanSummary,
        selectedRecords: [MemoryRuntimeSnapshotRecord],
        excludedRecords: [MemoryRuntimeSnapshotRecord],
        dereferenceCount: Int,
        warnings: [String],
        epistemicState: EpistemicState,
        influenceTrace: MemoryInfluenceTrace,
        renderedPrompt: String,
        metrics: MemoryRuntimeSnapshotMetrics
    ) {
        self.id = id
        self.sessionId = sessionId
        self.threadId = threadId
        self.workflowRunId = workflowRunId
        self.toolCallId = toolCallId
        self.agentRoundId = agentRoundId
        self.createdAt = createdAt
        self.request = request
        self.plan = plan
        self.selectedRecords = selectedRecords
        self.excludedRecords = excludedRecords
        self.dereferenceCount = dereferenceCount
        self.warnings = warnings
        self.epistemicState = epistemicState.stableSnapshot()
        self.influenceTrace = influenceTrace
        self.renderedPrompt = renderedPrompt
        self.metrics = metrics
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.threadId = try container.decode(String.self, forKey: .threadId)
        self.workflowRunId = try container.decodeIfPresent(String.self, forKey: .workflowRunId)
        self.toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        self.agentRoundId = try container.decodeIfPresent(UUID.self, forKey: .agentRoundId)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.request = try container.decode(MemoryRuntimeSnapshotRequestSummary.self, forKey: .request)
        self.plan = try container.decode(MemoryRuntimeSnapshotPlanSummary.self, forKey: .plan)
        self.selectedRecords = try container.decode([MemoryRuntimeSnapshotRecord].self, forKey: .selectedRecords)
        self.excludedRecords = try container.decode([MemoryRuntimeSnapshotRecord].self, forKey: .excludedRecords)
        self.dereferenceCount = try container.decode(Int.self, forKey: .dereferenceCount)
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.epistemicState = try container.decode(EpistemicState.self, forKey: .epistemicState)
        self.influenceTrace = try container.decode(MemoryInfluenceTrace.self, forKey: .influenceTrace)
        self.renderedPrompt = try container.decode(String.self, forKey: .renderedPrompt)
        self.metrics = try container.decode(MemoryRuntimeSnapshotMetrics.self, forKey: .metrics)
    }
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
        dereferenceCount: Int = 0,
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace(),
        retrievalIntent: MemoryRetrievalIntent? = nil,
        workingSetCost: Int = 0,
        renderedPrompt: String = "## 已验证事实\n- Fixture Record"
    ) -> MemoryRuntimeSnapshot {
        fixture(
            id: id,
            sessionId: sessionId,
            threadId: threadId,
            workflowRunId: workflowRunId,
            toolCallId: toolCallId,
            agentRoundId: agentRoundId,
            createdAt: createdAt,
            taskKind: taskKind,
            projectId: projectId,
            workspaceRoot: workspaceRoot,
            contextBudget: contextBudget,
            userRequest: userRequest,
            profileIDs: profileIDs,
            orderedLayers: orderedLayers,
            itemBudgetByLayer: itemBudgetByLayer,
            candidateScopes: candidateScopes,
            candidateCountByLayer: candidateCountByLayer,
            selectedCountByLayer: selectedCountByLayer,
            candidateCount: candidateCount,
            selectedRecords: selectedRecords,
            excludedRecords: excludedRecords,
            dereferenceCount: dereferenceCount,
            warnings: [],
            epistemicState: epistemicState,
            influenceTrace: influenceTrace,
            retrievalIntent: retrievalIntent,
            workingSetCost: workingSetCost,
            postEnforcementPromptChars: nil,
            trimmedCharCount: 0,
            trimmedSectionIDs: [],
            renderedPrompt: renderedPrompt
        )
    }

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
        dereferenceCount: Int = 0,
        warnings: [String] = [],
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace(),
        retrievalIntent: MemoryRetrievalIntent? = nil,
        workingSetCost: Int = 0,
        postEnforcementPromptChars: Int? = nil,
        trimmedCharCount: Int = 0,
        trimmedSectionIDs: [String] = [],
        renderedPrompt: String = "## 已验证事实\n- Fixture Record"
    ) -> MemoryRuntimeSnapshot {
        let selectedCount = selectedRecords.count
        let metrics = MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedCount,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars },
            postEnforcementPromptChars: postEnforcementPromptChars ?? renderedPrompt.count,
            trimmedCharCount: trimmedCharCount,
            trimmedSectionIDs: trimmedSectionIDs,
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
            dereferenceCount: dereferenceCount,
            warnings: warnings,
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
        dereferenceCount: Int = 0,
        totalEstimatedPromptChars: Int? = nil,
        postEnforcementPromptChars: Int? = nil,
        trimmedCharCount: Int = 0,
        trimmedSectionIDs: [String] = [],
        includeWorkingSetCost: Bool = false
    ) -> MemoryRuntimeSnapshotMetrics {
        let selectedRecordPromptChars = selectedRecords.reduce(0) { $0 + $1.estimatedPromptChars }
        let totalEstimatedPromptChars = max(totalEstimatedPromptChars ?? selectedRecordPromptChars, selectedRecordPromptChars)
        let postEnforcementPromptChars = postEnforcementPromptChars ?? totalEstimatedPromptChars
        let workingSetCost: Int
        if includeWorkingSetCost {
            workingSetCost = postEnforcementPromptChars + (dereferenceCount * 16)
        } else {
            workingSetCost = 0
        }

        return MemoryRuntimeSnapshotMetrics(
            candidateCount: candidateCount,
            selectedCount: selectedRecords.count,
            excludedCount: excludedRecords.count,
            totalEstimatedPromptChars: totalEstimatedPromptChars,
            postEnforcementPromptChars: postEnforcementPromptChars,
            trimmedCharCount: trimmedCharCount,
            trimmedSectionIDs: trimmedSectionIDs,
            workingSetCost: workingSetCost,
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