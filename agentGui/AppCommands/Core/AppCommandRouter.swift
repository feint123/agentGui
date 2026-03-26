import Foundation

@MainActor
final class AppCommandRouter {
    private let requestWorkspaceSelection: @MainActor () -> Void
    private let recentSessionProvider: RecentSessionProvider

    init(
        requestWorkspaceSelection: @escaping @MainActor () -> Void = WorkspaceDirectorySelectionCoordinator.requestFromSystemMenu,
        recentSessionProvider: RecentSessionProvider? = nil
    ) {
        self.requestWorkspaceSelection = requestWorkspaceSelection
        self.recentSessionProvider = recentSessionProvider ?? RecentSessionProvider()
    }

    func perform(_ commandID: AppCommandID, in context: AppCommandContext) async -> AppCommandResult {
        guard let descriptor = AppCommandRegistry().descriptor(for: commandID) else {
            return .failed("未找到命令描述。")
        }

        let availability = descriptor.requirement.evaluate(in: context)
        guard availability.isEnabled else {
            return .disabled(availability.disabledReason ?? "命令当前不可用。")
        }

        switch commandID {
        case .showCommandPalette:
            CommandPaletteWindowScene.requestPresentation(context: context)
            return .performed
        case .showSettings:
            return openWindow(SettingsWindowScene.id, in: context)
        case .openWorkspaceChooser:
            requestWorkspaceSelection()
            return .performed
        case .showAgentStudio:
            return openWindow(AgentStudioWindowScene.id, in: context)
        case .showSessionsPanel:
            context.workbenchState?.selectedItem = .sessions
            return .performed
        case .showWorkspacePanel:
            context.workbenchState?.selectedItem = .workspace
            return .performed
        case .showGitPanel:
            context.workbenchState?.selectedItem = .git
            return .performed
        case .showLSPPanel:
            context.workbenchState?.selectedItem = .lsp
            return .performed
        case .showSkillsPanel:
            context.workbenchState?.selectedItem = .skills
            return .performed
        case .showDiagnosticsPanel:
            context.workbenchState?.selectedItem = .diagnostics
            return .performed
        case .showNextSession:
            return switchSession(in: context, direction: .next)
        case .showPreviousSession:
            return switchSession(in: context, direction: .previous)
        case .openContextWindow:
            context.workspaceState?.openContextWindow()
            return .performed
        }
    }

    private func openWindow(_ id: String, in context: AppCommandContext) -> AppCommandResult {
        guard let openWindowByID = context.openWindowByID else {
            return .disabled("当前窗口不支持打开命令目标。")
        }
        openWindowByID(id)
        return .performed
    }

    private func switchSession(
        in context: AppCommandContext,
        direction: RecentSessionProvider.Direction
    ) -> AppCommandResult {
        guard let workspaceState = context.workspaceState else {
            return .disabled("当前没有可操作的工作台窗口。")
        }

        guard let session = recentSessionProvider.adjacentSession(
            from: workspaceState.selectedSession,
            direction: direction,
            modelContext: context.modelContext
        ) else {
            return .disabled("当前没有可切换的会话。")
        }

        workspaceState.selectedSession = session
        return .performed
    }
}