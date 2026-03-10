import Foundation
import Observation

@MainActor
@Observable
final class MemoryManagementViewModel {
    struct CountSummary: Identifiable, Equatable {
        let id: String
        let label: String
        let count: Int
    }

    private let store: UnifiedMemoryFileStoreAdapter
    private let confirmationStore: MemoryConfirmationStore
    private let confirmationWorkflowService: MemoryConfirmationWorkflowService
    private let backgroundJobStore: MemoryBackgroundJobStore
    private let retentionService: MemoryRetentionService

    var scopeSummaries: [CountSummary] = []
    var layerSummaries: [CountSummary] = []
    var archivedCount: Int = 0
    var conflictCount: Int = 0
    var pendingConfirmationCount: Int = 0
    var totalRecordCount: Int = 0
    var conflictRecords: [MemoryRecord] = []
    var pendingConfirmations: [MemoryConfirmationCandidate] = []
    var latestSweepReport: MemorySweepReport?

    init(
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter(),
        confirmationStore: MemoryConfirmationStore = MemoryConfirmationStore(),
        confirmationWorkflowService: MemoryConfirmationWorkflowService = MemoryConfirmationWorkflowService(),
        backgroundJobStore: MemoryBackgroundJobStore = MemoryBackgroundJobStore(),
        retentionService: MemoryRetentionService = MemoryRetentionService()
    ) {
        self.store = store
        self.confirmationStore = confirmationStore
        self.confirmationWorkflowService = confirmationWorkflowService
        self.backgroundJobStore = backgroundJobStore
        self.retentionService = retentionService
    }

    func reload() throws {
        let allRecords = try store.allRecords(includeArchived: true)
        let confirmations = try confirmationStore.load()
        latestSweepReport = backgroundJobStore.latestSweepReport()

        totalRecordCount = allRecords.count
        archivedCount = allRecords.filter { $0.retentionPolicy == .archiveOnly }.count
        conflictRecords = allRecords.filter { $0.supersededBy != nil }
        conflictCount = conflictRecords.count
        pendingConfirmations = confirmations
            .filter { $0.status == .pending }
            .sorted { $0.createdAt > $1.createdAt }
        pendingConfirmationCount = pendingConfirmations.count

        let scopeCounts = Dictionary(grouping: allRecords, by: { $0.scope.namespace })
            .map { CountSummary(id: $0.key, label: $0.key, count: $0.value.count) }
            .sorted { $0.label < $1.label }
        scopeSummaries = scopeCounts

        let layerCounts = Dictionary(grouping: allRecords, by: { $0.layer.rawValue })
            .map { CountSummary(id: $0.key, label: $0.key, count: $0.value.count) }
            .sorted { $0.label < $1.label }
        layerSummaries = layerCounts
    }

    func approve(candidateID: String) async throws {
        _ = try await confirmationWorkflowService.approve(candidateID: candidateID)
        try reload()
    }

    func reject(candidateID: String, reason: String) throws {
        _ = try confirmationWorkflowService.reject(candidateID: candidateID, reason: reason)
        try reload()
    }

    func runSweep(asOf: Date = Date(), ttl: TimeInterval = 60 * 60) throws {
        latestSweepReport = try retentionService.sweep(store: store, asOf: asOf, ttl: ttl)
        if let latestSweepReport {
            try backgroundJobStore.saveLatestSweepReport(latestSweepReport)
        }
        try reload()
    }
}