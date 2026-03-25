import Foundation
import SwiftData

enum AppFocusedSceneKind: Equatable {
    case none
    case workbench
    case contextWindow
    case settings
    case onboarding
    case agentStudio
}

@MainActor
struct AppCommandContext {
    var sceneID: UUID?
    var workspaceState: WorkspaceState?
    var workbenchState: WorkbenchState?
    var contextWindowState: WorkbenchContextWindowState?
    var modelContext: ModelContext?
    var focusedScene: AppFocusedSceneKind
    var openWindowByID: ((String) -> Void)?

    static let empty = AppCommandContext(
        sceneID: nil,
        workspaceState: nil,
        workbenchState: nil,
        contextWindowState: nil,
        modelContext: nil,
        focusedScene: .none,
        openWindowByID: nil
    )

    static func preview(
        sceneID: UUID? = nil,
        workspaceState: WorkspaceState? = nil,
        workbenchState: WorkbenchState? = nil,
        contextWindowState: WorkbenchContextWindowState? = nil,
        modelContext: ModelContext? = nil,
        focusedScene: AppFocusedSceneKind = .workbench,
        openWindowByID: ((String) -> Void)? = nil
    ) -> AppCommandContext {
        AppCommandContext(
            sceneID: sceneID,
            workspaceState: workspaceState,
            workbenchState: workbenchState,
            contextWindowState: contextWindowState,
            modelContext: modelContext,
            focusedScene: focusedScene,
            openWindowByID: openWindowByID
        )
    }
}