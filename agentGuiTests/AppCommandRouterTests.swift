import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct AppCommandRouterTests {
    @Test func sessionCommandIsDisabledWithoutWorkbenchContext() throws {
        let descriptor = try #require(AppCommandRegistry().descriptor(for: .showNextSession))

        #expect(descriptor.requirement.evaluate(in: .empty).isEnabled == false)
    }

    @Test func settingsCommandRoutesThroughOpenWindowWhenAvailable() async throws {
        let recorder = CommandRouteRecorder()
        let router = AppCommandRouter(
            requestWorkspaceSelection: recorder.requestWorkspaceSelection
        )

        let result = await router.perform(
            .showSettings,
            in: .preview(openWindowByID: recorder.openWindow)
        )

        #expect(result == .performed)
        #expect(recorder.openedWindowIDs == [SettingsWindowScene.id])
    }

    @Test func workspaceChooserCommandUsesInjectedRequestHook() async throws {
        let recorder = CommandRouteRecorder()
        let router = AppCommandRouter(
            requestWorkspaceSelection: recorder.requestWorkspaceSelection
        )

        let result = await router.perform(.openWorkspaceChooser, in: .empty)

        #expect(result == .performed)
        #expect(recorder.workspaceSelectionRequests == 1)
    }

    @Test func nextSessionCommandSelectsAdjacentSession() async throws {
        let container = try ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)

        let newest = Session.fixture(sessionId: "newest", title: "Newest")
        newest.updatedAt = Date(timeIntervalSince1970: 200)
        let older = Session.fixture(sessionId: "older", title: "Older")
        older.updatedAt = Date(timeIntervalSince1970: 100)

        modelContext.insert(newest)
        modelContext.insert(older)
        try modelContext.save()

        let workspaceState = WorkspaceState()
        let workbenchState = WorkbenchState()
        workspaceState.selectedSession = newest

        let context = AppCommandContext.preview(
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: .workbench
        )

        let result = await AppCommandRouter().perform(.showNextSession, in: context)

        #expect(result == .performed)
        #expect(workspaceState.selectedSession?.sessionId == "older")
    }
}

@MainActor
private final class CommandRouteRecorder {
    private(set) var openedWindowIDs: [String] = []
    private(set) var workspaceSelectionRequests = 0

    func openWindow(_ id: String) {
        openedWindowIDs.append(id)
    }

    func requestWorkspaceSelection() {
        workspaceSelectionRequests += 1
    }
}