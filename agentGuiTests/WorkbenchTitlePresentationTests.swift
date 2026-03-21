import Foundation
import Testing
@testable import agentGui

@MainActor
struct WorkbenchTitlePresentationTests {

    @Test func workspacePanelUsesGlobalWorkingDirectoryForTitleAndSubtitle() {
        let workspaceState = WorkspaceState()

        let presentation = WorkbenchTitlePresentation.make(
            selectedItem: .workspace,
            workspaceState: workspaceState,
            globalWorkingDirectory: "/tmp/Global Workspace"
        )

        #expect(presentation.title == "Global Workspace")
        #expect(presentation.subtitle == "/tmp/Global Workspace")
        #expect(presentation.representedURL?.path == "/tmp/Global Workspace")
    }

    @Test func workspacePanelPrefersSessionWorkingDirectoryOverride() {
        let workspaceState = WorkspaceState()
        workspaceState.selectedSession = Session.fixture(workingDirectory: "/tmp/Session Workspace")

        let presentation = WorkbenchTitlePresentation.make(
            selectedItem: .workspace,
            workspaceState: workspaceState,
            globalWorkingDirectory: "/tmp/Global Workspace"
        )

        #expect(presentation.title == "Session Workspace")
        #expect(presentation.subtitle == "/tmp/Session Workspace")
        #expect(presentation.representedURL?.path == "/tmp/Session Workspace")
    }

    @Test func nonWorkspacePanelsKeepOwnStaticTitle() {
        let workspaceState = WorkspaceState()

        let presentation = WorkbenchTitlePresentation.make(
            selectedItem: .git,
            workspaceState: workspaceState,
            globalWorkingDirectory: "/tmp/Global Workspace"
        )

        #expect(presentation.title == "Git")
        #expect(presentation.subtitle.isEmpty)
        #expect(presentation.representedURL == nil)
    }

    @Test func workspaceWithoutDirectoryFallsBackToGenericTitle() {
        let workspaceState = WorkspaceState()

        let presentation = WorkbenchTitlePresentation.make(
            selectedItem: .workspace,
            workspaceState: workspaceState,
            globalWorkingDirectory: ""
        )

        #expect(presentation.title == "工作区")
        #expect(presentation.subtitle.isEmpty)
        #expect(presentation.representedURL == nil)
    }
}