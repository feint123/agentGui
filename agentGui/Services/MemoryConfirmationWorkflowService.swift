import Foundation

struct MemoryConfirmationWorkflowService {
    private let confirmationStore: MemoryConfirmationStore
    private let unifiedStore: UnifiedMemoryFileStoreAdapter
    private let governanceService: MemoryGovernanceService
    private let auditFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default,
        governanceService: MemoryGovernanceService = MemoryGovernanceService()
    ) {
        self.confirmationStore = MemoryConfirmationStore(baseDirectory: baseDirectory, fileManager: fileManager)
        self.unifiedStore = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory, fileManager: fileManager)
        self.governanceService = governanceService
        self.auditFileURL = baseDirectory.appending(path: "memory-governance-audit.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadPending() throws -> [MemoryConfirmationCandidate] {
        try confirmationStore.load().filter { $0.status == .pending }
    }

    func loadAuditTrail() throws -> [MemoryGovernanceAuditEntry] {
        guard fileManager.fileExists(atPath: auditFileURL.path) else { return [] }
        let data = try Data(contentsOf: auditFileURL)
        return try decoder.decode([MemoryGovernanceAuditEntry].self, from: data)
    }

    func approve(candidateID: String) async throws -> MemoryConfirmationCandidate {
        var candidates = try confirmationStore.load()
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw MemoryStoreError.recordNotFound(candidateID)
        }

        var candidate = candidates[index]
        let record = try candidate.proposedRecord.toMemoryRecord()

        do {
            let writeResult = try persistApprovedRecord(record)
            candidate.status = .approved
            candidate.resolvedAt = Date()
            candidate.finalRecordID = writeResult.record.id
            candidate.rejectionReason = nil
            candidates[index] = candidate
            try confirmationStore.save(candidates)
            try appendAudit(
                MemoryGovernanceAuditEntry(
                    candidateID: candidate.id,
                    action: .approved,
                    finalRecordID: writeResult.record.id,
                    detail: describe(writeResult.action)
                )
            )
            return candidate
        } catch {
            candidate.status = .failedToApply
            candidate.resolvedAt = Date()
            candidates[index] = candidate
            try confirmationStore.save(candidates)
            try appendAudit(
                MemoryGovernanceAuditEntry(
                    candidateID: candidate.id,
                    action: .failedToApply,
                    detail: error.localizedDescription
                )
            )
            throw error
        }
    }

    func reject(candidateID: String, reason: String) throws -> MemoryConfirmationCandidate {
        var candidates = try confirmationStore.load()
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else {
            throw MemoryStoreError.recordNotFound(candidateID)
        }

        var candidate = candidates[index]
        candidate.status = .rejected
        candidate.resolvedAt = Date()
        candidate.rejectionReason = reason
        candidates[index] = candidate
        try confirmationStore.save(candidates)
        try appendAudit(
            MemoryGovernanceAuditEntry(
                candidateID: candidate.id,
                action: .rejected,
                rejectionReason: reason
            )
        )
        return candidate
    }

    private func persistApprovedRecord(_ record: MemoryRecord) throws -> MemoryWriteResult {
        let candidate = MemoryCandidate(
            id: record.id,
            layer: record.layer,
            kind: record.kind,
            domainProfile: record.domainProfile,
            scope: record.scope,
            title: record.title,
            summary: record.summary,
            payload: record.payload,
            confidence: record.confidence,
            verificationStatus: record.verificationStatus,
            sourceRefs: record.sourceRefs,
            tags: record.tags
        )
        let conflicts = governanceService.detectConflicts(for: candidate, store: unifiedStore)

        if let conflict = conflicts.first {
            return try unifiedStore.replace(recordID: conflict.existingRecordID, with: record)
        }

        return try unifiedStore.persist(record: record)
    }

    private func appendAudit(_ entry: MemoryGovernanceAuditEntry) throws {
        let directory = auditFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var entries = try loadAuditTrail()
        entries.append(entry)
        let data = try encoder.encode(entries)
        try data.write(to: auditFileURL, options: .atomic)
    }

    private func describe(_ action: MemoryWriteAction) -> String {
        switch action {
        case .inserted:
            return "inserted"
        case .updated:
            return "updated"
        case let .replaced(replacedRecordID):
            return "replaced \(replacedRecordID)"
        case let .archived(reason):
            return "archived \(reason.rawValue)"
        }
    }
}