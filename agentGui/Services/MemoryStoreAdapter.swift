import Foundation

protocol MemoryStoreAdapter {
    func records(for scope: MemoryScope) throws -> [MemoryRecord]

    func records(for scope: MemoryScope, includeArchived: Bool) throws -> [MemoryRecord]

    @discardableResult
    func persist(record: MemoryRecord) throws -> MemoryWriteResult

    @discardableResult
    func replace(recordID: String, with record: MemoryRecord) throws -> MemoryWriteResult

    @discardableResult
    func archive(recordID: String, reason: MemoryArchiveReason) throws -> MemoryWriteResult

    @discardableResult
    func touch(recordID: String, accessedAt: Date) throws -> MemoryRecord
}

extension MemoryStoreAdapter {
    func records(for scope: MemoryScope, includeArchived: Bool) throws -> [MemoryRecord] {
        let records = try records(for: scope)
        guard includeArchived else {
            return records.filter { $0.retentionPolicy != .archiveOnly }
        }
        return records
    }

    @discardableResult
    func persist(record: MemoryRecord) throws -> MemoryWriteResult {
        throw MemoryStoreError.unsupportedOperation("persist")
    }

    @discardableResult
    func replace(recordID: String, with record: MemoryRecord) throws -> MemoryWriteResult {
        _ = recordID
        _ = record
        throw MemoryStoreError.unsupportedOperation("replace")
    }

    @discardableResult
    func archive(recordID: String, reason: MemoryArchiveReason) throws -> MemoryWriteResult {
        _ = recordID
        _ = reason
        throw MemoryStoreError.unsupportedOperation("archive")
    }

    @discardableResult
    func touch(recordID: String, accessedAt: Date) throws -> MemoryRecord {
        _ = accessedAt
        throw MemoryStoreError.recordNotFound(recordID)
    }
}