import Foundation

struct MemoryRetentionService {
    private let lifecycleManager: MemoryLifecycleManager

    init(lifecycleManager: MemoryLifecycleManager = MemoryLifecycleManager()) {
        self.lifecycleManager = lifecycleManager
    }

    func sweep(
        store: UnifiedMemoryFileStoreAdapter,
        asOf: Date,
        ttl: TimeInterval
    ) throws -> MemorySweepReport {
        let expiredResults = try sweepExpiredSessionRecords(store: store, asOf: asOf, ttl: ttl)
        let rebalance = lifecycleManager.rebalance(records: try store.allRecords(includeArchived: true))
        for record in rebalance.updatedRecords {
            _ = try store.persist(record: record)
        }
        let revalidation = try revalidationQueue(store: store)
        return MemorySweepReport(
            runAt: asOf,
            archivedCount: expiredResults.count,
            revalidationCount: revalidation.count,
            skippedCount: 0
        )
    }

    func sweepExpiredSessionRecords(
        store: UnifiedMemoryFileStoreAdapter,
        asOf: Date,
        ttl: TimeInterval
    ) throws -> [MemoryWriteResult] {
        let expired = try store.allRecords(includeArchived: true).filter { record in
            record.retentionPolicy == .sessionBound &&
            asOf.timeIntervalSince(record.updatedAt) > ttl
        }

        return try expired.map { record in
            try store.archive(recordID: record.id, reason: .retentionExpired)
        }
    }

    func revalidationQueue(store: UnifiedMemoryFileStoreAdapter) throws -> [MemoryRecord] {
        try store.allRecords(includeArchived: true).filter {
            $0.retentionPolicy != .archiveOnly &&
            ($0.verificationStatus == .partial || $0.verificationStatus == .unverified)
        }
    }
}