import Foundation

final class CommandPalettePresentationRequest {
    let context: AppCommandContext

    init(context: AppCommandContext) {
        self.context = context
    }
}

enum CommandPaletteWindowScene {
    static let id = "command-palette-window"
    static let presentNotification = Notification.Name("CommandPaletteWindowScene.present")
    static let dismissNotification = Notification.Name("CommandPaletteWindowScene.dismiss")

    static func requestPresentation(context: AppCommandContext) {
        NotificationCenter.default.post(
            name: presentNotification,
            object: CommandPalettePresentationRequest(context: context)
        )
    }

    static func requestDismissal() {
        NotificationCenter.default.post(name: dismissNotification, object: nil)
    }
}