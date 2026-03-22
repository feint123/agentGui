import CryptoKit
import Foundation

struct ChangeReviewFileArtifact: Sendable, Equatable {
    let relativePath: String
    let absolutePath: String
    let changeKind: ProposedFileChangeKind
    let unifiedDiff: String
    let baseContentHash: String?
    let stagedContentHash: String?
    let baseContentSnapshot: String?
    let stagedContentSnapshot: String?
    let lineAdditions: Int
    let lineDeletions: Int
}

enum ChangeReviewArtifactBuilder {
    static func build(
        relativePath: String,
        absolutePath: String,
        changeKind: ProposedFileChangeKind? = nil,
        baseContent: String?,
        stagedContent: String?
    ) -> ChangeReviewFileArtifact {
        let resolvedChangeKind = changeKind ?? inferredChangeKind(baseContent: baseContent, stagedContent: stagedContent)
        let counts = lineCounts(baseContent: baseContent, stagedContent: stagedContent)

        return ChangeReviewFileArtifact(
            relativePath: relativePath,
            absolutePath: absolutePath,
            changeKind: resolvedChangeKind,
            unifiedDiff: unifiedDiff(
                relativePath: relativePath,
                changeKind: resolvedChangeKind,
                baseContent: baseContent,
                stagedContent: stagedContent
            ),
            baseContentHash: contentHash(for: baseContent),
            stagedContentHash: contentHash(for: stagedContent),
            baseContentSnapshot: baseContent,
            stagedContentSnapshot: stagedContent,
            lineAdditions: counts.additions,
            lineDeletions: counts.deletions
        )
    }

    static func contentHash(for text: String?) -> String? {
        guard let text else {
            return nil
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func lineCounts(baseContent: String?, stagedContent: String?) -> (additions: Int, deletions: Int) {
        let oldLines = splitLines(baseContent ?? "")
        let newLines = splitLines(stagedContent ?? "")
        return (additions: newLines.count, deletions: oldLines.count)
    }

    private static func inferredChangeKind(baseContent: String?, stagedContent: String?) -> ProposedFileChangeKind {
        switch (baseContent, stagedContent) {
        case (.none, .some):
            return .add
        case (.some, .none):
            return .delete
        case (.some, .some), (.none, .none):
            return .modify
        }
    }

    private static func unifiedDiff(
        relativePath: String,
        changeKind: ProposedFileChangeKind,
        baseContent: String?,
        stagedContent: String?
    ) -> String {
        let oldLines = splitLines(baseContent ?? "")
        let newLines = splitLines(stagedContent ?? "")
        let hunkHeader = hunkHeader(changeKind: changeKind, oldLines: oldLines, newLines: newLines)
        let deleted = oldLines.map { "-\($0)" }
        let added = newLines.map { "+\($0)" }

        return (["--- \(relativePath)", "+++ \(relativePath)", hunkHeader] + deleted + added)
            .joined(separator: "\n")
    }

    private static func hunkHeader(
        changeKind: ProposedFileChangeKind,
        oldLines: [String],
        newLines: [String]
    ) -> String {
        switch changeKind {
        case .add:
            return "@@ -0,0 +1,\(max(newLines.count, 1)) @@"
        case .delete:
            return "@@ -1,\(max(oldLines.count, 1)) +0,0 @@"
        case .modify, .rename:
            return "@@ -1,\(max(oldLines.count, 1)) +1,\(max(newLines.count, 1)) @@"
        }
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        return text.components(separatedBy: "\n")
    }
}

struct WorkspaceTextSnapshot: Sendable {
    struct FileEntry: Sendable, Equatable {
        let absolutePath: String
        let contents: String
    }

    let root: URL
    let filesByRelativePath: [String: FileEntry]
}

struct DetachedWorkspaceChangeCaptureExecutor: Sendable {
    typealias CaptureSnapshotOperation = @Sendable (URL) throws -> WorkspaceTextSnapshot
    typealias CollectArtifactsOperation = @Sendable (WorkspaceTextSnapshot) throws -> [ChangeReviewFileArtifact]

    private let captureSnapshotOperation: CaptureSnapshotOperation
    private let collectArtifactsOperation: CollectArtifactsOperation

    init(service: WorkspaceChangeCaptureService = WorkspaceChangeCaptureService()) {
        self.init(
            captureSnapshotOperation: { root in
                try service.captureSnapshot(root: root)
            },
            collectArtifactsOperation: { baseSnapshot in
                try service.collectArtifacts(from: baseSnapshot)
            }
        )
    }

    init(
        captureSnapshotOperation: @escaping CaptureSnapshotOperation,
        collectArtifactsOperation: @escaping CollectArtifactsOperation
    ) {
        self.captureSnapshotOperation = captureSnapshotOperation
        self.collectArtifactsOperation = collectArtifactsOperation
    }

    func captureSnapshot(root: URL) async throws -> WorkspaceTextSnapshot {
        let task = Task.detached(priority: .utility) {
            try captureSnapshotOperation(root)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func collectArtifacts(from baseSnapshot: WorkspaceTextSnapshot) async throws -> [ChangeReviewFileArtifact] {
        let task = Task.detached(priority: .utility) {
            try collectArtifactsOperation(baseSnapshot)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct WorkspaceChangeCaptureService: @unchecked Sendable {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func captureSnapshot(root: URL) throws -> WorkspaceTextSnapshot {
        let normalizedRoot = root.standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: normalizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return WorkspaceTextSnapshot(root: normalizedRoot, filesByRelativePath: [:])
        }

        var filesByRelativePath: [String: WorkspaceTextSnapshot.FileEntry] = [:]
        for case let fileURL as URL in enumerator {
            if Task.isCancelled {
                throw CancellationError()
            }

            let normalizedFileURL = fileURL.standardizedFileURL
            let values = try normalizedFileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let relativePath = String(normalizedFileURL.path.dropFirst(normalizedRoot.path.count + 1))
            guard let contents = try readableTextContents(at: normalizedFileURL) else {
                continue
            }
            filesByRelativePath[relativePath] = WorkspaceTextSnapshot.FileEntry(
                absolutePath: normalizedFileURL.path,
                contents: contents
            )
        }

        return WorkspaceTextSnapshot(root: normalizedRoot, filesByRelativePath: filesByRelativePath)
    }

    func collectArtifacts(from baseSnapshot: WorkspaceTextSnapshot) throws -> [ChangeReviewFileArtifact] {
        let stagedSnapshot = try captureSnapshot(root: baseSnapshot.root)
        return try collectArtifacts(from: baseSnapshot, to: stagedSnapshot)
    }

    func collectArtifacts(
        from baseSnapshot: WorkspaceTextSnapshot,
        to stagedSnapshot: WorkspaceTextSnapshot
    ) throws -> [ChangeReviewFileArtifact] {
        let allPaths = Set(baseSnapshot.filesByRelativePath.keys)
            .union(stagedSnapshot.filesByRelativePath.keys)
            .sorted()

        var artifacts: [ChangeReviewFileArtifact] = []
        for relativePath in allPaths {
            if Task.isCancelled {
                throw CancellationError()
            }

            let baseEntry = baseSnapshot.filesByRelativePath[relativePath]
            let stagedEntry = stagedSnapshot.filesByRelativePath[relativePath]
            let baseContent = baseEntry?.contents
            let stagedContent = stagedEntry?.contents

            guard baseContent != stagedContent else {
                continue
            }

            let absolutePath = stagedEntry?.absolutePath
                ?? baseEntry?.absolutePath
                ?? baseSnapshot.root.appending(path: relativePath).path

            artifacts.append(ChangeReviewArtifactBuilder.build(
                relativePath: relativePath,
                absolutePath: absolutePath,
                baseContent: baseContent,
                stagedContent: stagedContent
            ))
        }

        return artifacts
    }

    private func readableTextContents(at fileURL: URL) throws -> String? {
        if Task.isCancelled {
            throw CancellationError()
        }

        let data = try Data(contentsOf: fileURL)
        if Task.isCancelled {
            throw CancellationError()
        }
        guard !data.contains(0) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}