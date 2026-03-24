import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct WorkspaceStateTests {

    @Test func detailSelectionDefaultsToEmpty() {
        let workspaceState = WorkspaceState()

        #expect(workspaceState.detailSelection == .none)
    }

    @Test func workspaceDisplayUsesGlobalDirectoryWhenSessionHasNoOverride() {
        let workspaceState = WorkspaceState()

        #expect(workspaceState.effectiveWorkingDirectoryName(globalDefault: "/tmp/Global Workspace") == "Global Workspace")
        #expect(workspaceState.effectiveWorkingDirectoryPath(globalDefault: "/tmp/Global Workspace") == "/tmp/Global Workspace")
    }

    @Test func workspaceDisplayPrefersSessionDirectoryOverride() {
        let workspaceState = WorkspaceState()
        workspaceState.selectedSession = Session.fixture(workingDirectory: "/tmp/Session Workspace")

        #expect(workspaceState.effectiveWorkingDirectoryName(globalDefault: "/tmp/Global Workspace") == "Session Workspace")
        #expect(workspaceState.effectiveWorkingDirectoryPath(globalDefault: "/tmp/Global Workspace") == "/tmp/Session Workspace")
    }

    @Test func applyWorkspaceSelectionUpdatesSessionAndGlobalSettings() throws {
        let schema = Schema([AppSettings.self, Session.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let modelContext = container.mainContext
        let persistenceCoordinator = PersistenceCoordinator(saveOperation: { try $0.save() })
        let workspaceState = WorkspaceState()
        let session = Session.fixture(title: "Workspace Session")
        let selectedURL = URL(fileURLWithPath: "/tmp/Chosen Workspace")

        modelContext.insert(session)
        workspaceState.selectedSession = session

        let didApply = WorkspaceDirectorySelectionCoordinator.applySelection(
            selectedURL,
            workspaceState: workspaceState,
            modelContext: modelContext,
            persistenceCoordinator: persistenceCoordinator,
            userMessage: "工作目录未成功保存"
        )
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)

        #expect(didApply)
        #expect(session.workingDirectory == selectedURL.standardizedFileURL.path)
        #expect(settings.workingDirectory == selectedURL.standardizedFileURL.path)
        #expect(workspaceState.effectiveWorkingDirectoryPath(globalDefault: "") == selectedURL.standardizedFileURL.path)
    }

    @Test func selectedFileMirrorsTypedDetailSelection() {
        let workspaceState = WorkspaceState()
        let fileURL = URL(fileURLWithPath: "/tmp/repo/file.swift")

        workspaceState.selectedFile = fileURL

        #expect(workspaceState.detailSelection == .file(fileURL.standardizedFileURL))
    }

    @Test func selectedGitDiffMirrorsTypedDetailSelectionAndClearsProposalSelection() {
        let workspaceState = WorkspaceState()
        let proposalID = UUID()
        let diffURL = URL(fileURLWithPath: "/tmp/repo/file.swift")

        workspaceState.selectChangeProposal(proposalID, filePath: "file.swift")
        workspaceState.selectedGitDiffTitle = "file.swift"
        workspaceState.selectedGitDiffText = "diff --git a/file b/file"
        workspaceState.selectedGitDiffPath = diffURL

        #expect(workspaceState.detailSelection == .gitDiff(title: "file.swift", diffText: "diff --git a/file b/file"))
        #expect(workspaceState.selectedChangeProposalID == nil)
        #expect(workspaceState.selectedChangeProposalFilePath == nil)
    }

    @Test func selectingProposalMirrorsTypedDetailSelection() {
        let workspaceState = WorkspaceState()
        let proposalID = UUID()

        workspaceState.selectChangeProposal(proposalID, filePath: "README.md")

        #expect(workspaceState.detailSelection == .changeProposal(proposalID: proposalID, filePath: "README.md"))
    }

    @Test func showFileDetailOpensContextWindowTab() {
        let workspaceState = WorkspaceState()
        let contextWindowState = WorkbenchContextWindowState()
        let fileURL = URL(fileURLWithPath: "/tmp/repo/file.swift")

        workspaceState.contextWindowState = contextWindowState
        workspaceState.showFileDetail(fileURL)

        #expect(workspaceState.detailSelection == .file(fileURL.standardizedFileURL))
        #expect(contextWindowState.tabs.count == 1)
        #expect(contextWindowState.tabs.first?.selection == .file(fileURL.standardizedFileURL))
    }

    @Test func sceneServicesBuildCommandContextFromCurrentWorkbenchState() {
        let services = WorkbenchSceneServices()
        let session = Session.fixture(sessionId: "session-a", title: "A")
        services.workspaceState.selectedSession = session
        services.workbenchState.selectedItem = .workspace

        let context = services.makeCommandContext(
            focusedScene: .workbench,
            openWindowByID: nil,
            modelContext: nil
        )

        #expect(context.workspaceState?.selectedSession?.sessionId == session.sessionId)
        #expect(context.workbenchState?.selectedItem == .workspace)
        #expect(context.focusedScene == .workbench)
    }

    @Test func selectingProposalUpdatesContextWindowProposalPath() {
        let workspaceState = WorkspaceState()
        let contextWindowState = WorkbenchContextWindowState()
        let proposalID = UUID()

        workspaceState.contextWindowState = contextWindowState
        workspaceState.selectChangeProposal(proposalID, filePath: "A.swift")
        workspaceState.selectedChangeProposalFilePath = "B.swift"

        #expect(workspaceState.detailSelection == .changeProposal(proposalID: proposalID, filePath: "B.swift"))
        #expect(contextWindowState.tabs.count == 1)
        #expect(contextWindowState.tabs.first?.selection == .changeProposal(proposalID: proposalID, filePath: "B.swift"))
    }

    @Test func clearingTypedDetailSelectionClearsCompatibilityValues() {
        let workspaceState = WorkspaceState()
        let diffURL = URL(fileURLWithPath: "/tmp/repo/file.swift")

        workspaceState.showGitDiffDetail(
            path: diffURL,
            title: "file.swift",
            diffText: "diff --git a/file.swift b/file.swift"
        )
        workspaceState.showFileDetail(nil)

        #expect(workspaceState.detailSelection == .none)
        #expect(workspaceState.selectedFile == nil)
        #expect(workspaceState.selectedGitDiffPath == nil)
        #expect(workspaceState.selectedGitDiffTitle == nil)
        #expect(workspaceState.selectedGitDiffText == nil)
        #expect(workspaceState.selectedChangeProposalID == nil)
    }
}