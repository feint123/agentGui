import Foundation

struct MemoryRetentionService {
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