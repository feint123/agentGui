import SwiftUI

@MainActor
struct AppCommandMenuSupport {
    let registry = AppCommandRegistry()
    let router = AppCommandRouter()
    let focusedContext: AppCommandContext?
    let openWindow: OpenWindowAction
    let updateCommandHandler: UpdateCommandHandling?

    init(
        focusedContext: AppCommandContext?,
        openWindow: OpenWindowAction,
        updateCommandHandler: UpdateCommandHandling? = nil
    ) {
        self.focusedContext = focusedContext
        self.openWindow = openWindow
        self.updateCommandHandler = updateCommandHandler
    }

    func descriptor(for id: AppCommandID) -> AppCommandDescriptor? {
        registry.descriptor(for: id)
    }

    func context() -> AppCommandContext {
        var context = focusedContext ?? .empty
        if context.openWindowByID == nil {
            context.openWindowByID = { windowID in
                openWindow(id: windowID)
            }
        }
        if context.updateCommandHandler == nil {
            context.updateCommandHandler = updateCommandHandler
        }
        return context
    }

    func availability(for id: AppCommandID) -> AppCommandAvailability {
        guard let descriptor = descriptor(for: id) else {
            return .disabled("未找到命令描述。")
        }
        return descriptor.requirement.evaluate(in: context())
    }

    func perform(_ id: AppCommandID) {
        let resolvedContext = context()
        Task { @MainActor in
            _ = await router.perform(id, in: resolvedContext)
        }
    }
}

struct AppMenuCommands: Commands {
    @FocusedValue(\.appCommandContext) private var focusedCommandContext
    @Environment(\.openWindow) private var openWindow
    let updateCommandHandler: UpdateCommandHandling?

    init(updateCommandHandler: UpdateCommandHandling? = nil) {
        self.updateCommandHandler = updateCommandHandler
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            commandButton(.showCommandPalette)
        }

        CommandGroup(after: .appSettings) {
            commandButton(.checkForUpdates)
            commandButton(.showSettings)
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
            openWindow: openWindow,
            updateCommandHandler: updateCommandHandler
        )
    }
}

extension View {
    @ViewBuilder
    func appCommandShortcut(_ shortcut: AppCommandShortcut?) -> some View {
        if let shortcut, let key = shortcut.key.first {
            keyboardShortcut(KeyEquivalent(key), modifiers: shortcut.modifiers)
        } else {
            self
        }
    }
}