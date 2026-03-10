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

    var scopeSummaries: [CountSummary] = []
    var layerSummaries: [CountSummary] = []
    var archivedCount: Int = 0
    var conflictCount: Int = 0
    var pendingConfirmationCount: Int = 0
    var totalRecordCount: Int = 0
    var conflictRecords: [MemoryRecord] = []
    var pendingConfirmations: [MemoryConfirmationCandidate] = []

    init(
        store: UnifiedMemoryFileStoreAdapter = UnifiedMemoryFileStoreAdapter(),
        confirmationStore: MemoryConfirmationStore = MemoryConfirmationStore()
    ) {
        self.store = store
        self.confirmationStore = confirmationStore
    }

    func reload() throws {
        let allRecords = try store.allRecords(includeArchived: true)
        let confirmations = try confirmationStore.load()

        totalRecordCount = allRecords.count
        archivedCount = allRecords.filter { $0.retentionPolicy == .archiveOnly }.count
        conflictRecords = allRecords.filter { $0.supersededBy != nil }
        conflictCount = conflictRecords.count
        pendingConfirmations = confirmations.sorted { $0.createdAt > $1.createdAt }
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
}