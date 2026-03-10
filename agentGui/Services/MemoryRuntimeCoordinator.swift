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
        if let projectId = request.projectId {
            records.append(contentsOf: storyRecordsProvider(projectId))
        }

        let filteredRecords = filterAndBudget(records: records, with: plan)
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

        return MemoryRuntimeContext(
            profiles: baseContext.profiles,
            records: baseContext.records,
            writePolicy: baseContext.writePolicy,
            warnings: baseContext.warnings,
            renderedPrompt: promptAssembler.render(context: baseContext)
        )
    }

    private func filterAndBudget(records: [MemoryRecord], with plan: MemoryRetrievalPlan) -> [MemoryRecord] {
        let allowedLayers = Set(plan.orderedLayers)
        let scoped = records.filter {
            allowedLayers.contains($0.layer) && (plan.includeArchived || $0.retentionPolicy != .archiveOnly)
        }

        var result: [MemoryRecord] = []
        for layer in plan.orderedLayers {
            let layerRecords = scoped.filter { $0.layer == layer }.sorted(by: score(lhs:rhs:))
            let budget = plan.itemBudgetByLayer[layer] ?? layerRecords.count
            result.append(contentsOf: layerRecords.prefix(budget))
        }
        return result
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
}

extension MemoryRuntimeCoordinator {
    static func makeForTests(unifiedRecords: [MemoryRecord], storyRecords: [MemoryRecord]) -> MemoryRuntimeCoordinator {
        MemoryRuntimeCoordinator(
            storyRecordsProvider: { _ in storyRecords },
            unifiedRecordsProvider: { _ in unifiedRecords }
        )
    }
}