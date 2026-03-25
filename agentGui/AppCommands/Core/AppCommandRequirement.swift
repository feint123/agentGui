import Foundation

enum AppCommandRequirement: Equatable {
    case none
    case openWindow
    case workbench
    case workbenchWithSelectedSession

    @MainActor
    func evaluate(in context: AppCommandContext) -> AppCommandAvailability {
        switch self {
        case .none:
            return .enabled
        case .openWindow:
            return context.openWindowByID == nil ? .disabled("当前窗口不支持打开命令目标。") : .enabled
        case .workbench:
            guard context.focusedScene == .workbench,
                  context.workspaceState != nil,
                  context.workbenchState != nil else {
                return .disabled("当前没有可操作的工作台窗口。")
            }
            return .enabled
        case .workbenchWithSelectedSession:
            guard context.focusedScene == .workbench,
                  let workspaceState = context.workspaceState,
                  context.workbenchState != nil else {
                return .disabled("当前没有可操作的工作台窗口。")
            }
            guard workspaceState.selectedSession != nil else {
                return .disabled("当前没有选中的会话。")
            }
            return .enabled
        }
    }
}