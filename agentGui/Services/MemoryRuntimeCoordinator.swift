import Foundation
import SwiftData

@MainActor
final class MemoryRuntimeCoordinator {
    private let profileRegistry: MemoryDomainProfileRegistry
    private let retrievalPlanner: MemoryRetrievalPlanner
    private let storyRecordsProvider: (String) -> [MemoryRecord]
    private let unifiedRecordsProvider: (MemoryRuntimeRequest) -> [MemoryRecord]
    private let unifiedStoreBaseDirectory: URL
    private let backgroundWriteQueue: MemoryBackgroundWriteQueue
    private let confirmationStore: MemoryConfirmationStore
    private let consolidationEngine: MemoryConsolidationEngine
    private let promptAssembler: MemoryPromptAssembler
    private let backgroundJobStore: MemoryBackgroundJobStore

    init(
        profileRegistry: MemoryDomainProfileRegistry = MemoryDomainProfileRegistry(),
        retrievalPlanner: MemoryRetrievalPlanner = MemoryRetrievalPlanner(),
        storyRecordsProvider: @escaping (String) -> [MemoryRecord],
        unifiedRecordsProvider: @escaping (MemoryRuntimeRequest) -> [MemoryRecord] = { _ in [] },
        unifiedStoreBaseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        backgroundWriteQueue: MemoryBackgroundWriteQueue? = nil,
        confirmationStore: MemoryConfirmationStore? = nil,
        consolidationEngine: MemoryConsolidationEngine = MemoryConsolidationEngine(),
        promptAssembler: MemoryPromptAssembler = MemoryPromptAssembler(),
        backgroundJobStore: MemoryBackgroundJobStore? = nil
    ) {
        self.profileRegistry = profileRegistry
        self.retrievalPlanner = retrievalPlanner
        self.storyRecordsProvider = storyRecordsProvider
        self.unifiedRecordsProvider = unifiedRecordsProvider
        self.unifiedStoreBaseDirectory = unifiedStoreBaseDirectory
        self.backgroundWriteQueue = backgroundWriteQueue ?? MemoryBackgroundWriteQueue(storeBaseDirectory: unifiedStoreBaseDirectory)
        self.confirmationStore = confirmationStore ?? MemoryConfirmationStore(baseDirectory: unifiedStoreBaseDirectory)
        self.consolidationEngine = consolidationEngine
        self.promptAssembler = promptAssembler
        self.backgroundJobStore = backgroundJobStore ?? MemoryBackgroundJobStore(baseDirectory: unifiedStoreBaseDirectory)
    }

    convenience init(modelContext: ModelContext) {
        let unifiedStoreDirectory = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory)
        let unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreDirectory)
        self.init(
            storyRecordsProvider: { projectId in
                guard let uuid = UUID(uuidString: projectId) else { return [] }
                let adapter = StoryMemoryStoreAdapter(modelContext: modelContext)
                let semantic = (try? adapter.semanticRecords(projectId: uuid)) ?? []
                let episodic = (try? adapter.episodicRecords(projectId: uuid)) ?? []
                return semantic + episodic
            },
            unifiedRecordsProvider: { request in
                (try? unifiedStore.records(for: request)) ?? []
            },
            unifiedStoreBaseDirectory: unifiedStoreDirectory
        )
    }

    func prepareContext(for request: MemoryRuntimeRequest) async throws -> MemoryRuntimeContext {
        let profiles = profileRegistry.profiles(for: request)
        let plan = retrievalPlanner.makePlan(request: request, profiles: profiles)

        var records = unifiedRecordsProvider(request)
        if records.contains(where: { $0.layer == .working }) == false,
           let workingRecord = synthesizedWorkingRecord(for: request) {
            records.append(workingRecord)
        }
        if let projectId = request.projectId {
            records.append(contentsOf: storyRecordsProvider(projectId))
        }

        let filtered = filterAndBudget(records: records, with: plan)
        let filteredRecords = filtered.selectedRecords
        let touchedAt = Date()
        let unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: unifiedStoreBaseDirectory)
        for record in filteredRecords where records.contains(where: { $0.id == record.id }) {
            try? unifiedStore.touch(recordID: record.id, accessedAt: touchedAt)
        }
        let baseContext = MemoryRuntimeContext(
            profiles: profiles.map(\.id),
            records: filteredRecords,
            writePolicy: mergedWritePolicy(for: profiles, request: request),
            warnings: []
        )
        let renderedPrompt = promptAssembler.render(context: baseContext)
        let runtimeSnapshot = makeSnapshot(
            request: request,
            plan: plan,
            profiles: profiles.map(\.id),
            candidateRecords: records,
            selectedRecords: filtered.selectedRecords,
            excludedRecords: filtered.excludedRecords,
            candidateCountByLayer: filtered.candidateCountByLayer,
            selectedCountByLayer: filtered.selectedCountByLayer,
            renderedPrompt: renderedPrompt
        )

        return MemoryRuntimeContext(
            profiles: baseContext.profiles,
            records: baseContext.records,
            writePolicy: baseContext.writePolicy,
            warnings: baseContext.warnings,
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
    }

    func scheduleConsolidation(for outcome: MemoryRuntimeOutcome) async {
        try? backgroundJobStore.enqueue(.consolidation(outcome: outcome))
    }

    private func makeSnapshot(
        request: MemoryRuntimeRequest,
        plan: MemoryRetrievalPlan,
        profiles: [String],
        candidateRecords: [MemoryRecord],
        selectedRecords: [MemoryRecord],
        excludedRecords: [(MemoryRecord, MemoryRuntimeExclusionReason)],
        candidateCountByLayer: [MemoryLayer: Int],
        selectedCountByLayer: [MemoryLayer: Int],
        renderedPrompt: String
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
                selectedCountByLayer: selectedCountByLayer
            ),
            selectedRecords: selectedSnapshotRecords,
            excludedRecords: excludedSnapshotRecords,
            renderedPrompt: renderedPrompt,
            metrics: MemoryRuntimeSnapshot.makeMetrics(
                candidateCount: candidateRecords.count,
                selectedRecords: selectedSnapshotRecords,
                excludedRecords: excludedSnapshotRecords
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
    static func makeForTests(unifiedRecords: [MemoryRecord], storyRecords: [MemoryRecord]) -> MemoryRuntimeCoordinator {
        MemoryRuntimeCoordinator(
            storyRecordsProvider: { _ in storyRecords },
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