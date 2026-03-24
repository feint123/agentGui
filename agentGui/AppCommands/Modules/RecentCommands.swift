import SwiftUI

struct RecentCommands: Commands {
    @FocusedValue(\.appCommandContext) private var focusedCommandContext
    @Environment(\.openWindow) private var openWindow

    private let recentWorkspaceStore = RecentWorkspaceStore.shared
    private let recentSessionProvider = RecentSessionProvider()

    var body: some Commands {
        CommandMenu("最近项目") {
            let context = support.context()
            let workspaces = Array(recentWorkspaceStore.items.prefix(5))
            let sessions = Array(recentSessionProvider.recentSessions(modelContext: context.modelContext, limit: 5))

            if workspaces.isEmpty, sessions.isEmpty {
                Text("暂无最近项目")
            }

            ForEach(workspaces, id: \.id) { item in
                Button(item.displayName) {
                    openRecentWorkspace(URL(fileURLWithPath: item.path), context: context)
                }
                .disabled(context.modelContext == nil)
            }

            if !workspaces.isEmpty, !sessions.isEmpty {
                Divider()
            }

            ForEach(sessions, id: \.persistentModelID) { session in
                Button(session.title) {
                    context.workspaceState?.selectedSession = session
                }
                .disabled(context.workspaceState == nil)
            }
        }
    }

    private var support: AppCommandMenuSupport {
        AppCommandMenuSupport(
            focusedContext: focusedCommandContext,
            openWindow: openWindow
        )
    }

    private func openRecentWorkspace(_ url: URL, context: AppCommandContext) {
        guard let modelContext = context.modelContext else { return }
        _ = WorkspaceDirectorySelectionCoordinator.applySelection(
            url,
            workspaceState: context.workspaceState,
            modelContext: modelContext,
            persistenceCoordinator: .shared,
            userMessage: "工作目录未成功保存"
        )
    }
}