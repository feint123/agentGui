import AppKit

enum WorkspaceTreeKeyboardShortcut: Equatable {
    case newFile
    case newFolder
    case rename
    case delete
    case copyRelativePath
    case revealInFinder

    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> WorkspaceTreeKeyboardShortcut? {
        let cleanedModifiers = modifierFlags.intersection([.command, .shift, .option, .control])
        let normalizedCharacters = charactersIgnoringModifiers?.lowercased()

        switch (keyCode, normalizedCharacters, cleanedModifiers) {
        case (36, _, []), (76, _, []):
            return .rename
        case (51, _, []), (117, _, []):
            return .delete
        case (_, "c", [.command]):
            return .copyRelativePath
        case (_, "r", [.command]):
            return .revealInFinder
        case (_, "n", [.command]):
            return .newFile
        case (_, "n", [.command, .shift]), (_, "n", [.shift, .command]):
            return .newFolder
        default:
            return nil
        }
    }
}