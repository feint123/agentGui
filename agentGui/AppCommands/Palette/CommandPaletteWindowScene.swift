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

    static func requestPresentation(context: AppCommandContext) {
        NotificationCenter.default.post(
            name: presentNotification,
            object: CommandPalettePresentationRequest(context: context)
        )
    }
}