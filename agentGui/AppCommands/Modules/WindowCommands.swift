import SwiftUI

struct WindowCommands: Commands {
    @FocusedValue(\.appCommandContext) private var focusedCommandContext
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("上下文") {
            commandButton(.openContextWindow)
        }
    }

    @ViewBuilder
    private func commandButton(_ id: AppCommandID) -> some View {
        if let descriptor = support.descriptor(for: id) {
            Button(descriptor.title) {
                support.perform(id)
            }
            .disabled(!support.availability(for: id).isEnabled)
            .appCommandShortcut(descriptor.shortcut)
        }
    }

    private var support: AppCommandMenuSupport {
        AppCommandMenuSupport(
            focusedContext: focusedCommandContext,
            openWindow: openWindow
        )
    }
}