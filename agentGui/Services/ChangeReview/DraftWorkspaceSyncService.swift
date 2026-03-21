import Foundation

struct DraftWorkspaceFileChange: Sendable {
    let relativePath: String
    let absolutePath: String
    let changeKind: ProposedFileChangeKind
    let baseContentSnapshot: String?
    let stagedContentSnapshot: String?
}

struct DraftWorkspaceSyncService {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func writeDraft(_ change: DraftWorkspaceFileChange) throws {
        let fileURL = URL(fileURLWithPath: change.absolutePath)

        if let stagedContentSnapshot = change.stagedContentSnapshot {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try stagedContentSnapshot.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }

        switch change.changeKind {
        case .delete, .add, .modify, .rename:
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    func revertDraft(_ change: DraftWorkspaceFileChange) throws {
        let fileURL = URL(fileURLWithPath: change.absolutePath)

        if let baseContentSnapshot = change.baseContentSnapshot {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try baseContentSnapshot.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }

        switch change.changeKind {
        case .add, .modify, .rename, .delete:
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
}

extension ProposedFileChange {
    var draftWorkspaceFileChange: DraftWorkspaceFileChange {
        DraftWorkspaceFileChange(
            relativePath: relativePath,
            absolutePath: absolutePath,
            changeKind: changeKind,
            baseContentSnapshot: baseContentSnapshot,
            stagedContentSnapshot: stagedContentSnapshot
        )
    }
}