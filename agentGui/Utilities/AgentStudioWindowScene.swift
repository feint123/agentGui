import SwiftUI

enum AgentStudioWindowScene {
    static let id = "agent-studio-window"
}

struct StudioMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("显示 Agent 工作室") {
                openWindow(id: AgentStudioWindowScene.id)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}