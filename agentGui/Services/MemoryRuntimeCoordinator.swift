import Foundation
import SwiftData

@MainActor
final class MemoryRuntimeCoordinator {
    private let profileRegistry: MemoryDomainProfileRegistry
    private let retrievalPlanner: MemoryRetrievalPlanner
    private let featureConfiguration: MemoryRuntimeFeatureConfiguration
    private let unifiedRecordsProvider: (MemoryRuntimeRequest) -> [MemoryRecord]
    private let unifiedStoreBaseDirectory: URL
    private let backgroundWriteQueue: MemoryBackgroundWriteQueue
    private let confirmationStore: MemoryConfirmationStore
    private let consolidationEngine: MemoryConsolidationEngine
    private let promptAssembler: MemoryPromptAssembler
    private let backgroundJobStore: MemoryBackgroundJobStore
    private let evidenceResolver: MemoryEvidenceResolver
    private let businessLogSink: BusinessLogSink?

    init(
        profileRegistry: MemoryDomainProfileRegistry = MemoryDomainProfileRegistry(),
        retrievalPlanner: MemoryRetrievalPlanner = MemoryRetrievalPlanner(),
        featureConfiguration: MemoryRuntimeFeatureConfiguration = .allEnabled,
        unifiedRecordsProvider: @escaping (MemoryRuntimeRequest) -> [MemoryRecord] = { _ in [] },
        unifiedStoreBaseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        backgroundWriteQueue: MemoryBackgroundWriteQueue? = nil,
        confirmationStore: MemoryConfirmationStore? = nil,
        consolidationEngine: MemoryConsolidationEngine = MemoryConsolidationEngine(),
        promptAssembler: MemoryPromptAssembler = MemoryPromptAssembler(),
        backgroundJobStore: MemoryBackgroundJobStore? = nil,
        evidenceResolver: MemoryEvidenceResolver = MemoryEvidenceResolver(),
        businessLogSink: BusinessLogSink? = nil
    ) {
        self.profileRegistry = profileRegistry
        self.retrievalPlanner = retrievalPlanner
        self.featureConfiguration = featureConfiguration
        self.unifiedRecordsProvider = unifiedRecordsProvider
        self.unifiedStoreBaseDirectory = unifiedStoreBaseDirectory
        self.backgroundWriteQueue = backgroundWriteQueue ?? MemoryBackgroundWriteQueue(storeBaseDirectory: unifiedStoreBaseDirectory)
        self.confirmationStore = confirmationStore ?? MemoryConfirmationStore(baseDirectory: unifiedStoreBaseDirectory)
        self.consolidationEngine = consolidationEngine
        self.promptAssembler = promptAssembler
        self.backgroundJobStore = backgroundJobStore ?? MemoryBackgroundJobStore(baseDirectory: unifiedStoreBaseDirectory)
        self.evidenceResolver = evidenceResolver
        self.businessLogSink = businessLogSink
    }

    convenience init(modelContext: ModelContext) {
        let unifiedStoreDirectory = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory)
        let unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreDirectory)
        self.init(
            unifiedRecordsProvider: { request in
                (try? unifiedStore.records(for: request)) ?? []
            },
            unifiedStoreBaseDirectory: unifiedStoreDirectory
        )
    }

    func prepareContext(
        for request: MemoryRuntimeRequest,
        epistemicState: EpistemicState = EpistemicState(),
        influenceTrace: MemoryInfluenceTrace = MemoryInfluenceTrace()
    ) async throws -> MemoryRuntimeContext {
        MemoryBusinessLogger.emit(
            .memoryContextPreparationStarted,
            request: request,
            metadata: [
                "taskKind": request.taskKind.rawValue,
                "contextBudget": request.contextBudget
            ],
            sink: businessLogSink
        )

        let profiles = profileRegistry.profiles(for: request)
        let stableEpistemicState = epistemicState.stableSnapshot()
        let effectiveEpistemicState = featureConfiguration.enableEpistemicExtraction
            ? stableEpistemicState
            : EpistemicState()
        let retrievalEpistemicState = featureConfiguration.enableRMSRetrieval
            ? effectiveEpistemicState
            : EpistemicState()
        let phaseHint: MemoryRetrievalPhase? = featureConfiguration.enableRMSRetrieval && (
            !retrievalEpistemicState.frontiers.isEmpty ||
            !retrievalEpistemicState.counterexamples.isEmpty ||
            !retrievalEpistemicState.verificationDebt.isEmpty
        ) ? .frontierResolution : nil
        let retrievalIntent = MemoryRetrievalIntentClassifier().classify(
            request: request,
            phaseHint: phaseHint,
            epistemicState: retrievalEpistemicState
        )
        let plan = retrievalPlanner.makePlan(
            request: request,
            profiles: profiles,
            intent: retrievalIntent,
            epistemicState: retrievalEpistemicState
        )
        let nextInfluenceTrace = featureConfiguration.enableRMSRetrieval
            ? augment(influenceTrace: influenceTrace, with: effectiveEpistemicState, plan: plan)
            : influenceTrace

        var records = unifiedRecordsProvider(request)
        if records.contains(where: { $0.layer == .working }) == false,
           let workingRecord = synthesizedWorkingRecord(for: request) {
            records.append(workingRecord)
        }

        let filtered = filterAndBudget(records: records, with: plan)
        let filteredRecords = filtered.selectedRecords
        let evidenceResolution = evidenceResolver.resolve(for: filteredRecords)
        let touchedAt = Date()
        let unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreBaseDirectory)
        for record in filteredRecords where records.contains(where: { $0.id == record.id }) {
            try? unifiedStore.touch(recordID: record.id, accessedAt: touchedAt)
        }
        let baseContext = MemoryRuntimeContext(
            profiles: profiles.map(\.id),
            records: filteredRecords,
            writePolicy: mergedWritePolicy(for: profiles, request: request),
            warnings: [],
            epistemicState: effectiveEpistemicState,
            influenceTrace: nextInfluenceTrace
        )
        let promptSections = promptAssembler.sections(for: baseContext)
        let promptBudgetResult = MemoryPromptBudgetEnforcer().enforce(
            sections: promptSections,
            budget: request.contextBudget
        )
        let renderedPrompt = promptBudgetResult.renderedPrompt
        let runtimeSnapshot = makeSnapshot(
            request: request,
            plan: plan,
            retrievalIntent: retrievalIntent,
            profiles: profiles.map(\.id),
            candidateRecords: records,
            selectedRecords: filteredRecords,
            excludedRecords: filtered.excludedRecords,
            candidateCountByLayer: filtered.candidateCountByLayer,
            selectedCountByLayer: filtered.selectedCountByLayer,
            dereferenceCount: evidenceResolution.dereferenceCount,
            epistemicState: effectiveEpistemicState,
            influenceTrace: nextInfluenceTrace,
            renderedPrompt: renderedPrompt,
            promptBudgetResult: promptBudgetResult
        )

        MemoryBusinessLogger.emit(
            .memoryContextPrepared,
            request: request,
            metadata: [
                "profileCount": profiles.count,
                "candidateCount": records.count,
                "selectedCount": filteredRecords.count,
                "excludedCount": filtered.excludedRecords.count,
                "dereferenceCount": evidenceResolution.dereferenceCount
            ],
            sink: businessLogSink
        )

        return MemoryRuntimeContext(
            profiles: baseContext.profiles,
            records: baseContext.records,
            writePolicy: baseContext.writePolicy,
            warnings: baseContext.warnings,
            epistemicState: baseContext.epistemicState,
            influenceTrace: baseContext.influenceTrace,
            renderedPrompt: renderedPrompt,
            runtimeSnapshot: runtimeSnapshot
        )
    }

    private func filterAndBudget(records: [MemoryRecord], with plan: MemoryRetrievalPlan) -> SelectionTrace {
        let allowedLayers = Set(plan.orderedLayers)
        var eligible: [MemoryRecord] = []
        var excluded: [(MemoryRecord, MemoryRuntimeExclusionReason)] = []

        for record in records {
            guard allowedLayers.contains(record.layer) else {
                excluded.append((record, .layerNotPlanned))
                continue
            }
            guard plan.includeArchived || record.retentionPolicy != .archiveOnly else {
                excluded.append((record, .archived))
                continue
            }
            if record.supersededBy != nil {
                excluded.append((record, .duplicateOrSuperseded))
                continue
            }
            eligible.append(record)
        }

        var result: [MemoryRecord] = []
        var candidateCountByLayer: [MemoryLayer: Int] = [:]
        var selectedCountByLayer: [MemoryLayer: Int] = [:]
        for layer in plan.orderedLayers {
            let layerRecords = eligible.filter { $0.layer == layer }.sorted(by: score(lhs:rhs:))
            candidateCountByLayer[layer] = layerRecords.count
            let budget = plan.itemBudgetByLayer[layer] ?? layerRecords.count
            let selected = Array(layerRecords.prefix(budget))
            result.append(contentsOf: selected)
            selectedCountByLayer[layer] = selected.count

            if layerRecords.count > budget {
                for record in layerRecords.dropFirst(budget) {
                    excluded.append((record, .budgetTrimmed))
                }
            }
        }
        return SelectionTrace(
            selectedRecords: result,
            excludedRecords: excluded,
            candidateCountByLayer: candidateCountByLayer,
            selectedCountByLayer: selectedCountByLayer
        )
    }

    private func score(lhs: MemoryRecord, rhs: MemoryRecord) -> Bool {
        if lhs.verificationStatus == .verified && rhs.verificationStatus != .verified {
            return true
        }
        if lhs.verificationStatus != .verified && rhs.verificationStatus == .verified {
            return false
        }
        if lhs.lastAccessedAt != rhs.lastAccessedAt {
            return (lhs.lastAccessedAt ?? .distantPast) > (rhs.lastAccessedAt ?? .distantPast)
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func mergedWritePolicy(for profiles: [MemoryDomainProfile], request: MemoryRuntimeRequest) -> MemoryWritePolicy {
        if profiles.contains(where: { $0.writePolicy(for: request) == .readWrite }) {
            return .readWrite
        }
        if profiles.contains(where: { $0.writePolicy(for: request) == .readMostly }) {
            return .readMostly
        }
        return .readOnly
    }

    private func augment(
        influenceTrace: MemoryInfluenceTrace,
        with epistemicState: EpistemicState,
        plan: MemoryRetrievalPlan
    ) -> MemoryInfluenceTrace {
        let stableState = epistemicState.stableSnapshot()
        guard !stableState.frontiers.isEmpty else {
            return influenceTrace
        }

        var nextTrace = influenceTrace
        let budgetPool = [
            plan.objectBudgetByType[.counterexample, default: 0],
            plan.objectBudgetByType[.procedure, default: 0],
            plan.objectBudgetByType[.constraint, default: 0],
            plan.objectBudgetByType[.verificationDebt, default: 0]
        ].reduce(0, +)
        let allocatedPerFrontier = max(budgetPool / max(stableState.frontiers.count, 1), 1)

        for frontier in stableState.frontiers {
            let decision = MemoryInfluenceTrace.FrontierBudgetDecision(
                frontierID: frontier.id,
                allocatedBudget: allocatedPerFrontier,
                rationale: "\(frontier.impactLevel.rawValue) impact frontier drove RMS retrieval budget"
            )
            if !nextTrace.frontierBudgetDecisions.contains(decision) {
                nextTrace.frontierBudgetDecisions.append(decision)
            }
        }

        return nextTrace
    }

    func applyGovernedWrite(candidate: MemoryCandidate) async throws -> MemoryGovernedWriteResult {
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreBaseDirectory)
        return try await MemoryGovernanceService().route(
            candidate,
            store: store,
            backgroundQueue: backgroundWriteQueue,
            confirmationStore: confirmationStore
        )
    }

    func recordOutcome(_ outcome: MemoryRuntimeOutcome) async {
        let store = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreBaseDirectory)
        for record in outcome.records {
            _ = try? store.persist(record: record)
        }
        MemoryBusinessLogger.emit(
            .memoryOutcomeRecorded,
            request: outcome.request,
            metadata: ["recordCount": outcome.records.count],
            sink: businessLogSink
        )
    }

    func scheduleConsolidation(for outcome: MemoryRuntimeOutcome) async {
        try? backgroundJobStore.enqueue(.consolidation(outcome: outcome))
        if featureConfiguration.enableRMSDistillation {
            try? backgroundJobStore.enqueue(.counterexampleDistillation(outcome: outcome))
            try? backgroundJobStore.enqueue(.tacticKernelDistillation(outcome: outcome))
            try? backgroundJobStore.enqueue(.memoryInvalidation(outcome: outcome))
        }
        MemoryBusinessLogger.emit(
            .memoryConsolidationQueued,
            request: outcome.request,
            metadata: [
                "recordCount": outcome.records.count,
                "distillationEnabled": featureConfiguration.enableRMSDistillation
            ],
            sink: businessLogSink
        )
    }

    private func makeSnapshot(
        request: MemoryRuntimeRequest,
        plan: MemoryRetrievalPlan,
        retrievalIntent: MemoryRetrievalIntent?,
        profiles: [String],
        candidateRecords: [MemoryRecord],
        selectedRecords: [MemoryRecord],
        excludedRecords: [(MemoryRecord, MemoryRuntimeExclusionReason)],
        candidateCountByLayer: [MemoryLayer: Int],
        selectedCountByLayer: [MemoryLayer: Int],
        dereferenceCount: Int,
        epistemicState: EpistemicState,
        influenceTrace: MemoryInfluenceTrace,
        renderedPrompt: String,
        promptBudgetResult: MemoryPromptBudgetEnforcer.Result
    ) -> MemoryRuntimeSnapshot {
        let selectedSnapshotRecords = selectedRecords.enumerated().map { index, record in
            MemoryRuntimeSnapshotRecord(record: record, promptOrder: index)
        }
        let excludedSnapshotRecords = excludedRecords.map { record, reason in
            MemoryRuntimeSnapshotRecord(record: record, exclusionReason: reason)
        }

        return MemoryRuntimeSnapshot(
            id: UUID().uuidString,
            sessionId: request.sessionId,
            threadId: request.threadId,
            workflowRunId: request.workflowRunId,
            toolCallId: nil,
            agentRoundId: nil,
            createdAt: Date(),
            request: MemoryRuntimeSnapshotRequestSummary(
                sessionId: request.sessionId,
                threadId: request.threadId,
                workflowRunId: request.workflowRunId,
                taskKind: request.taskKind,
                projectId: request.projectId,
                workspaceRoot: request.workspaceRoot,
                contextBudget: request.contextBudget,
                userRequest: request.userRequest
            ),
            plan: MemoryRuntimeSnapshotPlanSummary(
                profileIDs: profiles,
                orderedLayers: plan.orderedLayers,
                itemBudgetByLayer: plan.itemBudgetByLayer,
                candidateScopes: candidateScopes(for: request).map(\.namespace),
                candidateCountByLayer: candidateCountByLayer,
                selectedCountByLayer: selectedCountByLayer,
                retrievalIntent: retrievalIntent
            ),
            selectedRecords: selectedSnapshotRecords,
            excludedRecords: excludedSnapshotRecords,
            dereferenceCount: dereferenceCount,
            warnings: [],
            epistemicState: epistemicState,
            influenceTrace: influenceTrace,
            renderedPrompt: renderedPrompt,
            metrics: MemoryRuntimeSnapshot.makeMetrics(
                candidateCount: candidateRecords.count,
                selectedRecords: selectedSnapshotRecords,
                excludedRecords: excludedSnapshotRecords,
                dereferenceCount: dereferenceCount,
                totalEstimatedPromptChars: promptBudgetResult.totalPromptChars,
                postEnforcementPromptChars: promptBudgetResult.postEnforcementPromptChars,
                trimmedCharCount: promptBudgetResult.trimmedCharCount,
                trimmedSectionIDs: promptBudgetResult.trimmedSectionIDs,
                includeWorkingSetCost: true
            )
        )
    }

    private func candidateScopes(for request: MemoryRuntimeRequest) -> [MemoryScope] {
        var scopes: [MemoryScope] = [.user]

        if let workspaceRoot = request.workspaceRoot, !workspaceRoot.isEmpty {
            scopes.append(.workspace(id: workspaceRoot))
        }

        if let projectId = request.projectId, !projectId.isEmpty {
            scopes.append(.project(id: projectId))
        }

        scopes.append(.session(id: request.sessionId))
        scopes.append(.thread(id: request.threadId))

        if let workflowRunId = request.workflowRunId, !workflowRunId.isEmpty {
            scopes.append(.workflowRun(id: workflowRunId))
        }

        return scopes
    }

    private func synthesizedWorkingRecord(for request: MemoryRuntimeRequest) -> MemoryRecord? {
        let summary = request.userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }

        let timestamp = Date()
        return MemoryRecord(
            id: "runtime-working-\(request.sessionId)-\(request.threadId)",
            layer: .working,
            kind: .working,
            domainProfile: primaryDomainProfileID(for: request),
            scope: .session(id: request.sessionId),
            title: "Current task focus",
            summary: summary,
            payload: .structured([
                "userRequest": summary,
                "taskKind": request.taskKind.rawValue
            ]),
            source: .system(name: "runtime-working-memory"),
            sourceRefs: [],
            confidence: 1.0,
            verificationStatus: .partial,
            retentionPolicy: .sessionBound,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAccessedAt: nil,
            supersededBy: nil,
            tags: ["runtime-working", "current-goal"]
        )
    }

    private func primaryDomainProfileID(for request: MemoryRuntimeRequest) -> String {
        profileRegistry.profiles(for: request).first?.id ?? "user-preferences"
    }
}

extension MemoryRuntimeCoordinator {
    static func makeForTests(unifiedRecords: [MemoryRecord]) -> MemoryRuntimeCoordinator {
        MemoryRuntimeCoordinator(
            unifiedRecordsProvider: { _ in unifiedRecords }
        )
    }
}

private struct SelectionTrace {
    var selectedRecords: [MemoryRecord]
    var excludedRecords: [(MemoryRecord, MemoryRuntimeExclusionReason)]
    var candidateCountByLayer: [MemoryLayer: Int]
    var selectedCountByLayer: [MemoryLayer: Int]
}