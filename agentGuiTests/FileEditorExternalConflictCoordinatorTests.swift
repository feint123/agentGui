import Foundation
import Testing
@testable import agentGui

@MainActor
struct FileEditorExternalConflictCoordinatorTests {

    @Test func matchingExternalChangeWithUnsavedEditsPresentsConflict() {
        let coordinator = FileEditorExternalConflictCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/notes.md")

        let outcome = coordinator.handleExternalChange(
            changedURL: fileURL,
            loadedURL: fileURL,
            hasUnsavedChanges: true
        )

        guard case .presentConflict(let conflict) = outcome else {
            Issue.record("Expected conflict presentation outcome")
            return
        }

        #expect(conflict.url == fileURL.standardizedFileURL)
        #expect(coordinator.pendingConflict?.url == fileURL.standardizedFileURL)
    }

    @Test func matchingExternalChangeWithoutUnsavedEditsReloadsImmediately() {
        let coordinator = FileEditorExternalConflictCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/notes.md")

        let outcome = coordinator.handleExternalChange(
            changedURL: fileURL,
            loadedURL: fileURL,
            hasUnsavedChanges: false
        )

        #expect(outcome == .reload(fileURL.standardizedFileURL))
        #expect(coordinator.pendingConflict == nil)
    }

    @Test func reloadDecisionClearsPendingConflictAndReturnsReloadURL() {
        let coordinator = FileEditorExternalConflictCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/notes.md")

        _ = coordinator.handleExternalChange(
            changedURL: fileURL,
            loadedURL: fileURL,
            hasUnsavedChanges: true
        )

        let outcome = coordinator.resolve(.reloadFromDisk)

        #expect(outcome == .reload(fileURL.standardizedFileURL))
        #expect(coordinator.pendingConflict == nil)
    }

    @Test func keepLocalDecisionClearsPendingConflictWithoutReloading() {
        let coordinator = FileEditorExternalConflictCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/notes.md")

        _ = coordinator.handleExternalChange(
            changedURL: fileURL,
            loadedURL: fileURL,
            hasUnsavedChanges: true
        )

        let outcome = coordinator.resolve(.keepLocalChanges)

        #expect(outcome == .none)
        #expect(coordinator.pendingConflict == nil)
    }

    @Test func saveSuccessClearsPendingConflictForSameFile() {
        let coordinator = FileEditorExternalConflictCoordinator()
        let fileURL = URL(fileURLWithPath: "/tmp/workspace/notes.md")

        _ = coordinator.handleExternalChange(
            changedURL: fileURL,
            loadedURL: fileURL,
            hasUnsavedChanges: true
        )

        coordinator.handleSuccessfulSave(for: fileURL)

        #expect(coordinator.pendingConflict == nil)
    }
}