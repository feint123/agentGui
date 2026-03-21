import Foundation
import SwiftData

enum DirectIntentBackendError: LocalizedError {
    case oldStringNotFound(String)
    case ambiguousOldString(count: Int, path: String)
    case failedToReadFile(String, String)

    var errorDescription: String? {
        switch self {
        case .oldStringNotFound(let path):
            return "Error: old_str not found in '\(path)'"
        case .ambiguousOldString(let count, let path):
            return "Error: old_str appears \(count) times in '\(path)' (ambiguous). Add more context."
        case .failedToReadFile(let path, let reason):
            return "Error reading '\(path)': \(reason)"
        }
    }
}

struct DirectIntentDraft: Sendable {
    let absolutePath: String
    let changeKind: ProposedFileChangeKind
    let originalText: String?
    let updatedText: String

    static func strReplace(path: String, oldStr: String, newStr: String) throws -> DirectIntentDraft {
        let originalText: String
        do {
            originalText = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw DirectIntentBackendError.failedToReadFile(path, error.localizedDescription)
        }

        let count = originalText.components(separatedBy: oldStr).count - 1
        if count == 0 {
            throw DirectIntentBackendError.oldStringNotFound(path)
        }
        if count > 1 {
            throw DirectIntentBackendError.ambiguousOldString(count: count, path: path)
        }

        let updatedText = originalText.replacingOccurrences(of: oldStr, with: newStr, options: .literal)
        return DirectIntentDraft(
            absolutePath: path,
            changeKind: .modify,
            originalText: originalText,
            updatedText: updatedText
        )
    }

    static func write(path: String, fileText: String) throws -> DirectIntentDraft {
        let fileManager = FileManager.default
        let fileURL = URL(fileURLWithPath: path)

        if fileManager.fileExists(atPath: path) {
            let originalText: String
            do {
                originalText = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                throw DirectIntentBackendError.failedToReadFile(path, error.localizedDescription)
            }
            return DirectIntentDraft(
                absolutePath: path,
                changeKind: .modify,
                originalText: originalText,
                updatedText: fileText
            )
        }

        return DirectIntentDraft(
            absolutePath: path,
            changeKind: .add,
            originalText: nil,
            updatedText: fileText
        )
    }

    static func insert(path: String, insertLine: Int, newStr: String) throws -> DirectIntentDraft {
        let originalText: String
        do {
            originalText = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw DirectIntentBackendError.failedToReadFile(path, error.localizedDescription)
        }

        var lines = originalText.components(separatedBy: "\n")
        let clampedIndex = max(0, min(insertLine, lines.count))
        lines.insert(contentsOf: newStr.components(separatedBy: "\n"), at: clampedIndex)

        return DirectIntentDraft(
            absolutePath: path,
            changeKind: .modify,
            originalText: originalText,
            updatedText: lines.joined(separator: "\n")
        )
    }
}

@MainActor
final class DirectIntentBackend {
    private let proposalStore: ChangeProposalStore
    private let projectionStore: ChangeReviewProjectionStore?
    private let workspaceSyncService: DraftWorkspaceSyncService

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator? = nil,
        projectionStore: ChangeReviewProjectionStore? = nil,
        workspaceSyncService: DraftWorkspaceSyncService = DraftWorkspaceSyncService()
    ) {
        self.proposalStore = ChangeProposalStore(
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
        self.projectionStore = projectionStore
        self.workspaceSyncService = workspaceSyncService
    }

    func captureStrReplace(
        path: String,
        oldStr: String,
        newStr: String,
        sessionID: String,
        providerID: ConversationExecutionProviderID = .builtInAgent,
        baseWorkspaceRoot: String? = nil
    ) async throws -> ChangeProposalReviewSnapshot {
        try await stageDraft(
            DirectIntentDraft.strReplace(path: path, oldStr: oldStr, newStr: newStr),
            sessionID: sessionID,
            providerID: providerID,
            baseWorkspaceRoot: baseWorkspaceRoot
        )
    }

    func captureWrite(
        path: String,
        fileText: String,
        sessionID: String,
        providerID: ConversationExecutionProviderID = .builtInAgent,
        baseWorkspaceRoot: String? = nil
    ) async throws -> ChangeProposalReviewSnapshot {
        try await stageDraft(
            DirectIntentDraft.write(path: path, fileText: fileText),
            sessionID: sessionID,
            providerID: providerID,
            baseWorkspaceRoot: baseWorkspaceRoot
        )
    }

    func captureInsert(
        path: String,
        insertLine: Int,
        newStr: String,
        sessionID: String,
        providerID: ConversationExecutionProviderID = .builtInAgent,
        baseWorkspaceRoot: String? = nil
    ) async throws -> ChangeProposalReviewSnapshot {
        try await stageDraft(
            DirectIntentDraft.insert(path: path, insertLine: insertLine, newStr: newStr),
            sessionID: sessionID,
            providerID: providerID,
            baseWorkspaceRoot: baseWorkspaceRoot
        )
    }

    func stageDraft(
        _ draft: DirectIntentDraft,
        sessionID: String,
        providerID: ConversationExecutionProviderID = .builtInAgent,
        baseWorkspaceRoot: String? = nil
    ) async throws -> ChangeProposalReviewSnapshot {
        let fileURL = URL(fileURLWithPath: draft.absolutePath).standardizedFileURL
        let workspaceRootURL = Self.resolveWorkspaceRoot(for: fileURL, explicitRoot: baseWorkspaceRoot)
        let relativePath = Self.relativePath(for: fileURL, workspaceRootURL: workspaceRootURL)
        let proposal = try await proposalStore.createProposal(
            sessionID: sessionID,
            jobID: nil,
            messageID: nil,
            providerID: providerID,
            baseWorkspaceRoot: workspaceRootURL.path
        )

        let artifact = ChangeReviewArtifactBuilder.build(
            relativePath: relativePath,
            absolutePath: fileURL.path,
            changeKind: draft.changeKind,
            baseContent: draft.originalText,
            stagedContent: draft.updatedText
        )

        try await proposalStore.upsertFileChange(
            proposalID: proposal.id,
            relativePath: artifact.relativePath,
            absolutePath: artifact.absolutePath,
            changeKind: artifact.changeKind,
            unifiedDiff: artifact.unifiedDiff,
            baseContentHash: artifact.baseContentHash,
            stagedContentHash: artifact.stagedContentHash,
            baseContentSnapshot: artifact.baseContentSnapshot,
            stagedContentSnapshot: artifact.stagedContentSnapshot,
            lineAdditions: artifact.lineAdditions,
            lineDeletions: artifact.lineDeletions
        )

        do {
            try workspaceSyncService.writeDraft(
                DraftWorkspaceFileChange(
                    relativePath: relativePath,
                    absolutePath: fileURL.path,
                    changeKind: draft.changeKind,
                    baseContentSnapshot: draft.originalText,
                    stagedContentSnapshot: draft.updatedText
                )
            )
        } catch {
            try? await proposalStore.updateProposal(
                proposalID: proposal.id,
                state: .failed,
                summary: "草稿同步失败：\(relativePath)"
            )
            throw error
        }

        try await proposalStore.updateProposal(
            proposalID: proposal.id,
            state: .readyForReview,
            summary: relativePath
        )

        let snapshot = try await proposalStore.reviewSnapshot(for: proposal.id)
        projectionStore?.set(snapshot)
        return snapshot
    }

    private static func resolveWorkspaceRoot(for fileURL: URL, explicitRoot: String?) -> URL {
        if let explicitRoot, !explicitRoot.isEmpty {
            return URL(fileURLWithPath: explicitRoot).standardizedFileURL
        }
        return fileURL.deletingLastPathComponent()
    }

    private static func relativePath(for fileURL: URL, workspaceRootURL: URL) -> String {
        let filePath = fileURL.path
        let rootPath = workspaceRootURL.path
        if filePath == rootPath {
            return fileURL.lastPathComponent
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return fileURL.lastPathComponent
    }

}