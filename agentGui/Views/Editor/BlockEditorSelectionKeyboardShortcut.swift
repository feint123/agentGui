import AppKit

enum BlockEditorSelectionKeyboardShortcut: Equatable {
    case copy
    case cut
    case delete
    case duplicate
    case selectAll
    case clearSelection

    static func resolve(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> BlockEditorSelectionKeyboardShortcut? {
        let cleanedModifiers = modifierFlags.intersection([.command, .shift, .option, .control])
        let normalizedCharacters = charactersIgnoringModifiers?.lowercased()

        switch (keyCode, normalizedCharacters, cleanedModifiers) {
        case (51, _, []), (117, _, []):
            return .delete
        case (_, "c", [.command]):
            return .copy
        case (_, "x", [.command]):
            return .cut
        case (_, "d", [.command]):
            return .duplicate
        case (_, "a", [.command]):
            return .selectAll
        case (53, _, []):
            return .clearSelection
        default:
            return nil
        }
    }
}