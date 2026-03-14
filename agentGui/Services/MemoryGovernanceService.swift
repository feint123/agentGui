import Foundation
import SwiftData
import SwiftAnthropic

struct MemoryGovernanceService {
    private let policy: MemoryAdmissionPolicy
    private let featureExtractor: MemoryAdmissionFeatureExtractor
    private let decisionImpactEvaluator: MemoryDecisionImpactEvaluator
    private let businessLogSink: BusinessLogSink?

    init(
        policy: MemoryAdmissionPolicy = DefaultMemoryAdmissionPolicy(),
        featureExtractor: MemoryAdmissionFeatureExtractor = MemoryAdmissionFeatureExtractor(),
        decisionImpactEvaluator: MemoryDecisionImpactEvaluator = MemoryDecisionImpactEvaluator(),
        businessLogSink: BusinessLogSink? = nil
    ) {
        self.policy = policy
        self.featureExtractor = featureExtractor
        self.decisionImpactEvaluator = decisionImpactEvaluator
        self.businessLogSink = businessLogSink
    }

    func evaluate(
        _ candidate: MemoryCandidate,
        request: MemoryRuntimeRequest? = nil,
        epistemicState: EpistemicState = EpistemicState()
    ) -> MemoryGovernanceEvaluation {
        let request = request ?? MemoryRuntimeRequest(
            sessionId: candidate.scope.identifierValue,
            threadId: "memory-governance",
            workflowRunId: nil,
            userRequest: candidate.summary,
            taskKind: inferredTaskKind(for: candidate),
            projectId: candidate.scope.projectID,
            workspaceRoot: nil,
            contextBudget: 4000
        )
        let assessment = decisionImpactEvaluator.assess(candidate: candidate, request: request, epistemicState: epistemicState)
        let features = featureExtractor.extract(from: candidate, assessment: assessment)
        let evaluation = policy.evaluate(candidate: candidate, features: features, assessment: assessment)
        MemoryBusinessLogger.emit(
            .memoryWriteEvaluated,
            candidate: candidate,
            metadata: [
                "route": evaluation.route.rawValue,
                "decisionDelta": features.decisionDelta,
                "transferability": features.transferability,
                "evidenceStrength": features.evidenceStrength,
                "decayResistance": features.decayResistance
            ],
            sink: businessLogSink
        )
        return evaluation
    }

    func route(
        _ candidate: MemoryCandidate,
        store: UnifiedMemoryFileStoreAdapter,
        backgroundQueue: MemoryBackgroundWriteQueue,
        confirmationStore: MemoryConfirmationStore
    ) async throws -> MemoryGovernedWriteResult {
        let evaluation = evaluate(candidate)
        let record = candidate.asMemoryRecord(admissionExplanation: evaluation.explanation)
        let conflicts = detectConflicts(for: candidate, store: store)
        let result: MemoryGovernedWriteResult

        switch evaluation.route {
        case .acceptHotPath:
            let writeResult: MemoryWriteResult
            if let conflict = conflicts.first {
                writeResult = try store.replace(recordID: conflict.existingRecordID, with: record)
            } else {
                writeResult = try store.persist(record: record)
            }
            result = .hotPath(writeResult)
        case .acceptBackground:
            await backgroundQueue.enqueue(record)
            result = .backgroundQueued(recordID: record.id)
        case .archiveOnly:
            let archivedRecord = record.replacing(retentionPolicy: .archiveOnly, updatedAt: Date())
            let writeResult = try store.persist(record: archivedRecord)
            result = .archived(MemoryWriteResult(record: writeResult.record, action: .archived(reason: .governance)))
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
            result = .confirmationRequired(confirmation)
        case .reject:
            result = .rejected(reason: "Memory governance rejected this candidate due to low confidence.")
        }

        MemoryBusinessLogger.emit(
            .memoryWriteRouted,
            candidate: candidate,
            metadata: [
                "route": evaluation.route.rawValue,
                "conflictCount": conflicts.count,
                "result": describe(result)
            ],
            sink: businessLogSink
        )
        return result
    }

    func detectConflicts(for candidate: MemoryCandidate, store: UnifiedMemoryFileStoreAdapter) -> [MemoryConflict] {
        let existing = (try? store.records(for: candidate.scope, includeArchived: true)) ?? []
        return MemoryConflictResolver().detectConflicts(for: candidate, existingRecords: existing)
    }
}

private extension MemoryGovernanceService {
    func inferredTaskKind(for candidate: MemoryCandidate) -> MemoryTaskKind {
        switch candidate.domainProfile {
        case "creative-writing":
            return .creativeWriting
        case "coding-task":
            return .coding
        default:
            return .generalAssistant
        }
    }

    func describe(_ result: MemoryGovernedWriteResult) -> String {
        switch result {
        case .hotPath:
            return "hotPath"
        case .backgroundQueued:
            return "backgroundQueued"
        case .archived:
            return "archived"
        case .confirmationRequired:
            return "confirmationRequired"
        case .rejected:
            return "rejected"
        }
    }
}

private extension MemoryScope {
    var identifierValue: String {
        switch self {
        case let .workspace(id), let .project(id), let .session(id), let .thread(id), let .workflowRun(id):
            return id
        case .user:
            return "user"
        }
    }

    var projectID: String? {
        if case let .project(id) = self {
            return id
        }
        return nil
    }
}

extension MemoryCandidate {
    func asMemoryRecord(
        source: MemoryRecord.Source = .system(name: "memory-governance"),
        admissionExplanation: MemoryAdmissionExplanation? = nil
    ) -> MemoryRecord {
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
            tags: tags,
            admissionExplanation: admissionExplanation
        )
    }
}

actor MemoryBackgroundWriteQueue {
    private let storeBaseDirectory: URL
    private let jobStore: MemoryBackgroundJobStore

    init(storeBaseDirectory: URL = ConfigDirectoryManager.shared.agentGuiDir.appending(path: "unified-memory", directoryHint: .isDirectory)) {
        self.storeBaseDirectory = storeBaseDirectory
        self.jobStore = MemoryBackgroundJobStore(baseDirectory: storeBaseDirectory)
    }

    func enqueue(_ record: MemoryRecord) {
        try? jobStore.enqueue(.backgroundWrite(record: record))
    }

    func waitUntilIdle(timeoutNanoseconds: UInt64 = 1_000_000_000) async {
        let start = DispatchTime.now().uptimeNanoseconds
        let scheduler = await MainActor.run { MemoryBackgroundScheduler(baseDirectory: storeBaseDirectory) }
        while (try? jobStore.hasPendingJobs(types: [.backgroundWrite])) == true {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                return
            }
            await scheduler.runOnce()
            await Task.yield()
        }
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
        var candidates = try load()
        candidates.append(candidate)
        try save(candidates)
    }

    func save(_ candidates: [MemoryConfirmationCandidate]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

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

        let domainProfile = "user-preferences"

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