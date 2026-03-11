import Foundation
import Observation

struct FileEditorExternalConflict: Equatable {
    let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }
}

enum FileEditorExternalConflictDecision {
    case keepLocalChanges
    case reloadFromDisk
}

enum FileEditorExternalConflictOutcome: Equatable {
    case none
    case reload(URL)
    case presentConflict(FileEditorExternalConflict)
}

@Observable
@MainActor
final class FileEditorExternalConflictCoordinator {
    private(set) var pendingConflict: FileEditorExternalConflict?

    func handleExternalChange(changedURL: URL, loadedURL: URL?, hasUnsavedChanges: Bool) -> FileEditorExternalConflictOutcome {
        let changedURL = changedURL.standardizedFileURL
        guard let loadedURL else { return .none }

        let normalizedLoadedURL = loadedURL.standardizedFileURL
        guard changedURL == normalizedLoadedURL else { return .none }

        if hasUnsavedChanges {
            let conflict = FileEditorExternalConflict(url: changedURL)
            pendingConflict = conflict
            return .presentConflict(conflict)
        }

        pendingConflict = nil
        return .reload(changedURL)
    }

    func resolve(_ decision: FileEditorExternalConflictDecision) -> FileEditorExternalConflictOutcome {
        guard let pendingConflict else { return .none }
        self.pendingConflict = nil

        switch decision {
        case .keepLocalChanges:
            return .none
        case .reloadFromDisk:
            return .reload(pendingConflict.url)
        }
    }

    func handleSuccessfulSave(for url: URL) {
        guard pendingConflict?.url == url.standardizedFileURL else { return }
        pendingConflict = nil
    }

    func clear() {
        pendingConflict = nil
    }
}