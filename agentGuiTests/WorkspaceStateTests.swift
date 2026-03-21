import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct WorkspaceStateTests {

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
}