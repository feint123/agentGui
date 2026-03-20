import AppKit
import Testing
@testable import agentGui

@MainActor
struct WorkspaceTreeKeyboardShortcutTests {

    @Test func returnMapsToRename() {
        let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: 36,
            charactersIgnoringModifiers: "\r",
            modifierFlags: []
        )

        #expect(action == .rename)
    }

    @Test func deleteMapsToDeleteSelection() {
        let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: 51,
            charactersIgnoringModifiers: nil,
            modifierFlags: []
        )

        #expect(action == .delete)
    }

    @Test func commandCMapsToCopyRelativePath() {
        let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            modifierFlags: [.command]
        )

        #expect(action == .copyRelativePath)
    }

    @Test func commandShiftNMapsToNewFolder() {
        let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: 45,
            charactersIgnoringModifiers: "N",
            modifierFlags: [.command, .shift]
        )

        #expect(action == .newFolder)
    }

    @Test func commandRMapsToRevealInFinder() {
        let action = WorkspaceTreeKeyboardShortcut.resolve(
            keyCode: 15,
            charactersIgnoringModifiers: "r",
            modifierFlags: [.command]
        )

        #expect(action == .revealInFinder)
    }
}