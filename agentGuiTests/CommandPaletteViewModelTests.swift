import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct CommandPaletteViewModelTests {
    @Test func filteringMatchesCommandsRecentsAndFiles() throws {
        let suiteName = "CommandPaletteViewModelTests.\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let recentWorkspaceStore = RecentWorkspaceStore(defaults: defaults, storageKey: "palette-recents")
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("main.swift")
        try "print(1)".write(to: fileURL, atomically: true, encoding: .utf8)
        recentWorkspaceStore.record(rootURL)

        let container = try ModelContainer(for: AppSettings.self, Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Session One", workingDirectory: rootURL.path)
        session.updatedAt = Date(timeIntervalSince1970: 300)
        modelContext.insert(session)
        try modelContext.save()

        let workspaceState = WorkspaceState()
        let workbenchState = WorkbenchState()
        workspaceState.selectedSession = session

        let viewModel = CommandPaletteViewModel(
            sceneID: UUID(),
            quickOpenProvider: QuickOpenProvider(
                recentWorkspaceStore: recentWorkspaceStore,
                recentSessionProvider: RecentSessionProvider(),
                workspaceFileSearchIndex: WorkspaceFileSearchIndex()
            )
        )

        viewModel.present(using: AppCommandContext.preview(
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: .workbench,
            openWindowByID: { _ in }
        ))

        viewModel.query = "main"
        #expect(viewModel.results.contains(where: { $0.title == "main.swift" }))

        viewModel.query = "命令"
        #expect(viewModel.results.contains(where: { $0.title == "命令面板..." }))

        viewModel.query = rootURL.lastPathComponent
        #expect(viewModel.results.contains(where: { $0.subtitle == rootURL.path }))

        try? FileManager.default.removeItem(at: rootURL)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func executingFileResultOpensFileDetail() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("notes.md")
        try "# Notes".write(to: fileURL, atomically: true, encoding: .utf8)

        let container = try ModelContainer(for: AppSettings.self, Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Session One", workingDirectory: rootURL.path)
        modelContext.insert(session)
        try modelContext.save()

        let workspaceState = WorkspaceState()
        workspaceState.selectedSession = session

        let viewModel = CommandPaletteViewModel(sceneID: UUID())
        viewModel.present(using: AppCommandContext.preview(
            workspaceState: workspaceState,
            workbenchState: WorkbenchState(),
            modelContext: modelContext,
            focusedScene: .workbench,
            openWindowByID: { _ in }
        ))
        viewModel.query = "notes"

        let item = try #require(viewModel.results.first(where: { $0.title == "notes.md" }))
        let didExecute = await viewModel.execute(item)

        #expect(didExecute)
        #expect(workspaceState.selectedFile == fileURL.standardizedFileURL)

        try? FileManager.default.removeItem(at: rootURL)
    }

    @Test func emptyQueryGroupsRecentResultsBeforeCommands() throws {
        let suiteName = "CommandPaletteViewModelTests.\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let recentWorkspaceStore = RecentWorkspaceStore(defaults: defaults, storageKey: "palette-recents")
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        recentWorkspaceStore.record(rootURL)

        let container = try ModelContainer(for: AppSettings.self, Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let session = Session.fixture(sessionId: "session-1", title: "Recent Session", workingDirectory: rootURL.path)
        session.updatedAt = Date(timeIntervalSince1970: 300)
        modelContext.insert(session)
        try modelContext.save()

        let workspaceState = WorkspaceState()
        workspaceState.selectedSession = session

        let viewModel = CommandPaletteViewModel(
            sceneID: UUID(),
            quickOpenProvider: QuickOpenProvider(
                recentWorkspaceStore: recentWorkspaceStore,
                recentSessionProvider: RecentSessionProvider(),
                workspaceFileSearchIndex: WorkspaceFileSearchIndex()
            )
        )

        viewModel.present(using: AppCommandContext.preview(
            workspaceState: workspaceState,
            workbenchState: WorkbenchState(),
            modelContext: modelContext,
            focusedScene: .workbench,
            openWindowByID: { _ in }
        ))

        let groups: [CommandPaletteItemGroup] = viewModel.sections.map(\.group)

        #expect(groups.starts(with: [CommandPaletteItemGroup.recentSessions, CommandPaletteItemGroup.recentWorkspaces]))
        #expect(groups.contains(CommandPaletteItemGroup.commands))

        try? FileManager.default.removeItem(at: rootURL)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func dismissNotificationMarksPaletteHidden() {
        let viewModel = CommandPaletteViewModel(sceneID: UUID())

        viewModel.present(using: AppCommandContext.empty)
        #expect(viewModel.isPresented)

        CommandPaletteWindowScene.requestDismissal()

        #expect(viewModel.isPresented == false)
    }
}