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

        #expect(presentation.title == "未设置工作区")
        #expect(presentation.subtitle.isEmpty)
        #expect(presentation.representedURL == nil)
    }

    @Test func fileContextPresentationUsesFileNameAndPath() {
        let presentation = WorkbenchTitlePresentation.make(
            contextSelection: .file(URL(fileURLWithPath: "/tmp/repo/File.swift")),
            changeReviewProjectionStore: ChangeReviewProjectionStore()
        )

        #expect(presentation.title == "File.swift")
        #expect(presentation.subtitle == "/tmp/repo/File.swift")
        #expect(presentation.representedURL?.path == "/tmp/repo/File.swift")
    }

    @Test func changeProposalContextPresentationUsesSnapshotSummary() {
        let proposalID = UUID()
        let store = ChangeReviewProjectionStore()
        store.set(
            ChangeProposalReviewSnapshot(
                proposal: ChangeProposalSnapshot(
                    id: proposalID,
                    sessionID: "session-1",
                    jobID: nil,
                    messageID: nil,
                    providerID: .claudeAdapterCLI,
                    state: .collecting,
                    baseWorkspaceRoot: "/tmp/repo",
                    summary: "Improve tabbing",
                    createdAt: Date(),
                    updatedAt: Date()
                ),
                fileChanges: []
            )
        )

        let presentation = WorkbenchTitlePresentation.make(
            contextSelection: .changeProposal(proposalID: proposalID, filePath: nil),
            changeReviewProjectionStore: store
        )

        #expect(presentation.title == "Improve tabbing")
        #expect(presentation.subtitle == "Improve tabbing")
        #expect(presentation.representedURL == nil)
    }
}