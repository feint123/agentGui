import Foundation
import SwiftData
import SwiftAnthropic

struct MemoryGovernanceService {
    func evaluate(_ candidate: MemoryCandidate) -> MemoryGovernanceDecision {
        if candidate.domainProfile == "coding-task",
           candidate.layer == .task,
           candidate.kind == .working,
           candidate.verificationStatus == .verified,
           candidate.confidence >= 0.95 {
            return .acceptHotPath
        }

        if candidate.domainProfile == "creative-writing",
           candidate.layer == .semantic,
           candidate.kind == .semantic,
           candidate.verificationStatus != .verified,
           candidate.confidence < 0.6 {
            return .needsUserConfirmation
        }

        if candidate.confidence >= 0.7 {
            return .acceptBackground
        }

        if candidate.confidence >= 0.5 {
            return .archiveOnly
        }

        return .reject
    }

    func route(
        _ candidate: MemoryCandidate,
        store: UnifiedMemoryFileStoreAdapter,
        backgroundQueue: MemoryBackgroundWriteQueue,
        confirmationStore: MemoryConfirmationStore
    ) async throws -> MemoryGovernedWriteResult {
        let decision = evaluate(candidate)
        let record = candidate.asMemoryRecord()
        let conflicts = detectConflicts(for: candidate, store: store)

        switch decision {
        case .acceptHotPath:
            let result: MemoryWriteResult
            if let conflict = conflicts.first {
                result = try store.replace(recordID: conflict.existingRecordID, with: record)
            } else {
                result = try store.persist(record: record)
            }
            return .hotPath(result)
        case .acceptBackground:
            await backgroundQueue.enqueue(record)
            return .backgroundQueued(recordID: record.id)
        case .archiveOnly:
            let archivedRecord = record.replacing(retentionPolicy: .archiveOnly, updatedAt: Date())
            let result = try store.persist(record: archivedRecord)
            return .archived(MemoryWriteResult(record: result.record, action: .archived(reason: .governance)))
        case .needsUserConfirmation:
            let confirmation = MemoryConfirmationCandidate(
                candidateID: candidate.id,
                domainProfile: candidate.domainProfile,
                scope: candidate.scope,
                title: candidate.title,
                summary: candidate.summary,
                proposedRecord: UnifiedMemoryStoredRecord(record: record),
                reason: "Speculative memory requires user confirmation before persistence."
            )
            try confirmationStore.append(confirmation)
            return .confirmationRequired(confirmation)
        case .reject:
            return .rejected(reason: "Memory governance rejected this candidate due to low confidence.")
        }
    }

    func detectConflicts(for candidate: MemoryCandidate, store: UnifiedMemoryFileStoreAdapter) -> [MemoryConflict] {
        let existing = (try? store.records(for: candidate.scope, includeArchived: true)) ?? []
        return MemoryConflictResolver().detectConflicts(for: candidate, existingRecords: existing)
    }
}

extension MemoryCandidate {
    func asMemoryRecord(source: MemoryRecord.Source = .system(name: "memory-governance")) -> MemoryRecord {
        MemoryRecord(
            id: id,
            layer: layer,
            kind: kind,
            domainProfile: domainProfile,
            scope: scope,
            title: title,
            summary: summary,
            payload: payload,
            source: source,
            sourceRefs: sourceRefs,
            confidence: confidence,
            verificationStatus: verificationStatus,
            retentionPolicy: layer == .semantic ? .persistent : .sessionBound,
            createdAt: Date(),
            updatedAt: Date(),
            lastAccessedAt: nil,
            supersededBy: nil,
            tags: tags
        )
    }
}

actor MemoryBackgroundWriteQueue {
    private let storeBaseDirectory: URL
    private var pendingRecordIDs: Set<String> = []

    init(storeBaseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory)) {
        self.storeBaseDirectory = storeBaseDirectory
    }

    func enqueue(_ record: MemoryRecord) {
        pendingRecordIDs.insert(record.id)
        let baseDirectory = storeBaseDirectory
        Task {
            let store = UnifiedMemoryFileStoreAdapter(baseDirectory: baseDirectory)
            _ = try? store.persist(record: record)
            await self.markFinished(record.id)
        }
    }

    func waitUntilIdle(timeoutNanoseconds: UInt64 = 1_000_000_000) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !pendingRecordIDs.isEmpty {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                return
            }
            await Task.yield()
        }
    }

    private func markFinished(_ recordID: String) {
        pendingRecordIDs.remove(recordID)
    }
}

struct MemoryConfirmationStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.fileURL = baseDirectory.appending(path: "pending-confirmations.json")
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> [MemoryConfirmationCandidate] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([MemoryConfirmationCandidate].self, from: data)
    }

    func append(_ candidate: MemoryConfirmationCandidate) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var candidates = try load()
        candidates.append(candidate)
        let data = try encoder.encode(candidates)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension ClaudeService {
    func executeGovernedMemoryWrite(
        input: MessageResponse.Content.Input,
        session: Session?,
        modelContext: ModelContext
    ) async -> String {
        guard let content = input["content"]?.stringValue else {
            return "Error: missing 'content' parameter"
        }

        let sessionForDecision: Session?
        if let session {
            sessionForDecision = session
        } else if let sessionId = input["session_id"]?.stringValue {
            let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.sessionId == sessionId })
            sessionForDecision = try? modelContext.fetch(descriptor).first
        } else {
            sessionForDecision = nil
        }

        let domainProfile: String
        if let sessionForDecision, !sessionForDecision.activeWritingProjectId.isEmpty {
            domainProfile = "creative-writing"
        } else {
            domainProfile = "user-preferences"
        }

        let verificationStatus: MemoryRecord.VerificationStatus = inferredVerificationStatus(for: content, domainProfile: domainProfile)
        let confidence = inferredConfidence(for: content, domainProfile: domainProfile)
        let scope: MemoryScope = sessionForDecision.map { .session(id: $0.sessionId) } ?? .user
        let candidate = MemoryCandidate.fixture(
            layer: .semantic,
            kind: .semantic,
            domainProfile: domainProfile,
            scope: scope,
            title: String(content.prefix(80)),
            summary: content,
            payload: .text(content),
            confidence: confidence,
            verificationStatus: verificationStatus
        )

        let coordinator = MemoryRuntimeCoordinator(modelContext: modelContext)

        do {
            let result = try await coordinator.applyGovernedWrite(candidate: candidate)
            switch result {
            case let .hotPath(writeResult):
                return "Memory persisted to unified store (hot path, action: \(describe(writeResult.action)))."
            case let .backgroundQueued(recordID):
                return "Memory queued for background persistence (record: \(recordID))."
            case let .archived(writeResult):
                return "Memory routed to archive instead of live prompt memory (action: \(describe(writeResult.action)))."
            case let .confirmationRequired(confirmation):
                return "Memory write requires user confirmation (candidate: \(confirmation.id))."
            case let .rejected(reason):
                return "Error: \(reason)"
            }
        } catch {
            return "Error writing governed memory: \(error.localizedDescription)"
        }
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

    private func inferredVerificationStatus(for content: String, domainProfile: String) -> MemoryRecord.VerificationStatus {
        if domainProfile == "creative-writing" && containsSpeculativeLanguage(content) {
            return .unverified
        }
        return .verified
    }

    private func inferredConfidence(for content: String, domainProfile: String) -> Double {
        if domainProfile == "creative-writing" && containsSpeculativeLanguage(content) {
            return 0.45
        }
        return 1.0
    }

    private func containsSpeculativeLanguage(_ content: String) -> Bool {
        let lower = content.lowercased()
        let markers = ["可能", "也许", "猜测", "大概", "maybe", "perhaps", "likely", "probably"]
        return markers.contains { lower.contains($0) }
    }
}