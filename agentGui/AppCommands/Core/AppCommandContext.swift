import Foundation
import SwiftData

@MainActor
protocol UpdateCommandHandling: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

enum AppFocusedSceneKind: Equatable {
    case none
    case workbench
    case contextWindow
    case settings
    case agentStudio
}

@MainActor
struct AppCommandContext {
    var sceneID: UUID?
    var workspaceState: WorkspaceState?
    var workbenchState: WorkbenchState?
    var modelContext: ModelContext?
    var focusedScene: AppFocusedSceneKind
    var openWindowByID: ((String) -> Void)?
    var updateCommandHandler: UpdateCommandHandling? = nil

    static let empty = AppCommandContext(
        sceneID: nil,
        workspaceState: nil,
        workbenchState: nil,
        modelContext: nil,
        focusedScene: .none,
        openWindowByID: nil,
        updateCommandHandler: nil
    )

    static func preview(
        sceneID: UUID? = nil,
        workspaceState: WorkspaceState? = nil,
        workbenchState: WorkbenchState? = nil,
        modelContext: ModelContext? = nil,
        focusedScene: AppFocusedSceneKind = .workbench,
        openWindowByID: ((String) -> Void)? = nil,
        updateCommandHandler: UpdateCommandHandling? = nil
    ) -> AppCommandContext {
        AppCommandContext(
            sceneID: sceneID,
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            modelContext: modelContext,
            focusedScene: focusedScene,
            openWindowByID: openWindowByID,
            updateCommandHandler: updateCommandHandler
        )
    }
}