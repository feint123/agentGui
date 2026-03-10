import Foundation

struct UnifiedMemoryFileStoreAdapter: MemoryStoreAdapter {
    private let baseDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func records(for scope: MemoryScope) throws -> [MemoryRecord] {
        try records(for: scope, includeArchived: false)
    }

    func records(for scope: MemoryScope, includeArchived: Bool) throws -> [MemoryRecord] {
        let stored = try loadStoredRecords(scope: scope)
        var mapped: [MemoryRecord] = []
        for storedRecord in stored {
            mapped.append(try storedRecord.toMemoryRecord())
        }
        if includeArchived {
            return mapped.sorted { $0.createdAt < $1.createdAt }
        }
        return mapped
            .filter { $0.retentionPolicy != .archiveOnly }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func persist(record: MemoryRecord) throws -> MemoryWriteResult {
        try ensureBaseDirectoryExists()
        var stored = try loadStoredRecords(scope: record.scope)
        let action: MemoryWriteAction

        if let index = stored.firstIndex(where: { $0.id == record.id }) {
            stored[index] = UnifiedMemoryStoredRecord(record: record)
            action = .updated
        } else {
            stored.append(UnifiedMemoryStoredRecord(record: record))
            action = .inserted
        }

        try saveStoredRecords(stored, scope: record.scope)
        return MemoryWriteResult(record: record, action: action)
    }

    @discardableResult
    func replace(recordID: String, with record: MemoryRecord) throws -> MemoryWriteResult {
        try ensureBaseDirectoryExists()
        var existing = try findRecord(id: recordID)

        if var oldRecord = existing.record {
            oldRecord.supersededBy = record.id
            oldRecord.updatedAt = record.updatedAt
            existing.records[existing.index] = UnifiedMemoryStoredRecord(record: oldRecord)
            try saveStoredRecords(existing.records, scope: oldRecord.scope)
        }

        _ = try persist(record: record)
        return MemoryWriteResult(record: record, action: .replaced(replacedRecordID: recordID))
    }

    @discardableResult
    func archive(recordID: String, reason: MemoryArchiveReason) throws -> MemoryWriteResult {
        try ensureBaseDirectoryExists()
        var existing = try findRecord(id: recordID)
        guard var record = existing.record else {
            throw MemoryStoreError.recordNotFound(recordID)
        }

        record.retentionPolicy = .archiveOnly
        record.updatedAt = Date()
        existing.records[existing.index] = UnifiedMemoryStoredRecord(record: record)
        try saveStoredRecords(existing.records, scope: record.scope)
        return MemoryWriteResult(record: record, action: .archived(reason: reason))
    }

    @discardableResult
    func touch(recordID: String, accessedAt: Date) throws -> MemoryRecord {
        try ensureBaseDirectoryExists()
        var existing = try findRecord(id: recordID)
        guard var record = existing.record else {
            throw MemoryStoreError.recordNotFound(recordID)
        }

        record.lastAccessedAt = accessedAt
        existing.records[existing.index] = UnifiedMemoryStoredRecord(record: record)
        try saveStoredRecords(existing.records, scope: record.scope)
        return record
    }

    func records(for request: MemoryRuntimeRequest) throws -> [MemoryRecord] {
        try scopedRecords(for: request)
    }

    func allRecords(includeArchived: Bool = true) throws -> [MemoryRecord] {
        var all: [MemoryRecord] = []
        for fileURL in try scopeFileURLs() {
            let stored = try loadStoredRecords(fileURL: fileURL)
            for storedRecord in stored {
                all.append(try storedRecord.toMemoryRecord())
            }
        }

        let filtered = includeArchived ? all : all.filter { $0.retentionPolicy != .archiveOnly }
        return filtered.sorted { lhs, rhs in
            if lhs.scope.namespace == rhs.scope.namespace {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.scope.namespace < rhs.scope.namespace
        }
    }

    private func scopedRecords(for request: MemoryRuntimeRequest) throws -> [MemoryRecord] {
        var collected: [MemoryRecord] = []
        let scopes = candidateScopes(for: request)
        for scope in scopes {
            collected.append(contentsOf: try records(for: scope))
        }
        return collected
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

    private func findRecord(id: String) throws -> (scope: MemoryScope, records: [UnifiedMemoryStoredRecord], index: Int, record: MemoryRecord?) {
        for fileURL in try scopeFileURLs() {
            let stored = try loadStoredRecords(fileURL: fileURL)
            if let index = stored.firstIndex(where: { $0.id == id }) {
                let record = try stored[index].toMemoryRecord()
                return (record.scope, stored, index, record)
            }
        }
        throw MemoryStoreError.recordNotFound(id)
    }

    private func scopeFileURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { fileURL in
                fileURL.pathExtension == "json" &&
                fileURL.lastPathComponent != "pending-confirmations.json" &&
                fileURL.lastPathComponent != "memory-governance-audit.json" &&
                fileURL.lastPathComponent != "memory-background-jobs.json" &&
                fileURL.lastPathComponent != "memory-latest-sweep-report.json"
            }
    }

    private func loadStoredRecords(scope: MemoryScope) throws -> [UnifiedMemoryStoredRecord] {
        try loadStoredRecords(fileURL: fileURL(for: scope))
    }

    private func loadStoredRecords(fileURL: URL) throws -> [UnifiedMemoryStoredRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([UnifiedMemoryStoredRecord].self, from: data)
    }

    private func saveStoredRecords(_ records: [UnifiedMemoryStoredRecord], scope: MemoryScope) throws {
        try ensureBaseDirectoryExists()
        let data = try encoder.encode(records)
        try data.write(to: fileURL(for: scope), options: .atomic)
    }

    private func ensureBaseDirectoryExists() throws {
        guard !fileManager.fileExists(atPath: baseDirectory.path) else { return }
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for scope: MemoryScope) -> URL {
        let sanitizedNamespace = scope.namespace
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "__")
        return baseDirectory.appending(path: "\(sanitizedNamespace).json")
    }
}