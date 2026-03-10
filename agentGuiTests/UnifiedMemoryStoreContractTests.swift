import Foundation
import Testing
@testable import agentGui

@MainActor
struct UnifiedMemoryStoreContractTests {
    @Test func storeContractSupportsReplaceArchiveAndTouchSemantics() async throws {
        let store = InMemoryUnifiedMemoryStore()
        let scope = MemoryScope.session(id: "session-1")
        let initial = MemoryRecord.fixture(
            id: "record-1",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "Known fact",
            summary: "Known fact",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        _ = try store.persist(record: initial)
        let touchedAt = Date(timeIntervalSince1970: 20)
        let touched = try store.touch(recordID: initial.id, accessedAt: touchedAt)

        #expect(touched.lastAccessedAt == touchedAt)

        let replacement = MemoryRecord.fixture(
            id: "record-2",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "Updated fact",
            summary: "Updated fact",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        let writeResult = try store.replace(recordID: initial.id, with: replacement)
        #expect(writeResult.record.id == replacement.id)

        let records = try store.records(for: scope)
        let superseded = try #require(records.first(where: { $0.id == initial.id }))
        #expect(superseded.supersededBy == replacement.id)
        #expect(records.contains { $0.id == replacement.id })
    }

    @Test func archivedRecordsAreHiddenByDefault() async throws {
        let store = InMemoryUnifiedMemoryStore()
        let scope = MemoryScope.session(id: "session-2")
        let record = MemoryRecord.fixture(
            id: "archived-record",
            layer: .semantic,
            kind: .semantic,
            scope: scope,
            title: "Outdated fact",
            summary: "Outdated fact"
        )

        _ = try store.persist(record: record)
        _ = try store.archive(recordID: record.id, reason: .superseded)

        #expect(try store.records(for: scope).isEmpty)

        let allRecords = try store.records(for: scope, includeArchived: true)
        let archived = try #require(allRecords.first)
        #expect(archived.retentionPolicy == .archiveOnly)
    }
}

private final class InMemoryUnifiedMemoryStore: MemoryStoreAdapter {
    private var recordsByID: [String: MemoryRecord] = [:]

    func records(for scope: MemoryScope) throws -> [MemoryRecord] {
        try records(for: scope, includeArchived: false)
    }

    func records(for scope: MemoryScope, includeArchived: Bool) throws -> [MemoryRecord] {
        recordsByID.values
            .filter { $0.scope == scope }
            .filter { includeArchived || $0.retentionPolicy != .archiveOnly }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func persist(record: MemoryRecord) throws -> MemoryWriteResult {
        recordsByID[record.id] = record
        return MemoryWriteResult(record: record, action: .inserted)
    }

    @discardableResult
    func replace(recordID: String, with record: MemoryRecord) throws -> MemoryWriteResult {
        if var existing = recordsByID[recordID] {
            existing.supersededBy = record.id
            recordsByID[recordID] = existing
        }
        recordsByID[record.id] = record
        return MemoryWriteResult(record: record, action: .replaced(replacedRecordID: recordID))
    }

    @discardableResult
    func archive(recordID: String, reason: MemoryArchiveReason) throws -> MemoryWriteResult {
        guard var existing = recordsByID[recordID] else {
            throw MemoryStoreError.recordNotFound(recordID)
        }
        existing.retentionPolicy = .archiveOnly
        existing.updatedAt = Date(timeIntervalSince1970: 40)
        recordsByID[recordID] = existing
        return MemoryWriteResult(record: existing, action: .archived(reason: reason))
    }

    @discardableResult
    func touch(recordID: String, accessedAt: Date) throws -> MemoryRecord {
        guard var existing = recordsByID[recordID] else {
            throw MemoryStoreError.recordNotFound(recordID)
        }
        existing.lastAccessedAt = accessedAt
        recordsByID[recordID] = existing
        return existing
    }
}