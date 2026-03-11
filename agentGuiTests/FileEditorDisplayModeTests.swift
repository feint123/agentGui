import Foundation
import Testing
@testable import agentGui

@MainActor
struct FileEditorDisplayModeTests {

    @Test func resolvesGitDiffModeWhenWorkspaceHasDiffText() {
        let workspaceState = WorkspaceState()
        workspaceState.selectedGitDiffPath = URL(fileURLWithPath: "/tmp/repo/file.swift")
        workspaceState.selectedGitDiffTitle = "file.swift"
        workspaceState.selectedGitDiffText = "diff --git a/file.swift b/file.swift"
        workspaceState.selectedFile = URL(fileURLWithPath: "/tmp/repo/file.swift")

        let mode = FileEditorDisplayMode.resolve(from: workspaceState)

        #expect(mode == .gitDiff(title: "file.swift", diffText: "diff --git a/file.swift b/file.swift"))
    }

    @Test func resolvesSelectedFileModeWhenNoGitDiffIsActive() {
        let workspaceState = WorkspaceState()
        let fileURL = URL(fileURLWithPath: "/tmp/repo/file.swift")
        workspaceState.selectedFile = fileURL

        let mode = FileEditorDisplayMode.resolve(from: workspaceState)

        #expect(mode == .file(fileURL))
    }

    @Test func resolvesEmptyModeWhenNoFileOrDiffExists() {
        let workspaceState = WorkspaceState()

        let mode = FileEditorDisplayMode.resolve(from: workspaceState)

        #expect(mode == .empty)
    }
}