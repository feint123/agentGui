import Foundation
import Testing
@testable import agentGui

struct TerminalScreenModelTests {

    @Test func screenModelWritesPrintedTextAtCursorPosition() {
        var screen = TerminalScreenModel(width: 20, height: 8)
        screen.apply(.print("hello"))

        let snapshot = screen.snapshot()

        #expect(snapshot.plainTextLines.first == "hello")
        #expect(snapshot.cursor.row == 0)
        #expect(snapshot.cursor.column == 5)
    }

    @Test func screenModelSwitchesBetweenPrimaryAndAlternateBuffers() {
        var screen = TerminalScreenModel(width: 20, height: 8)
        screen.apply(.print("shell"))
        screen.apply(.enterAlternateScreen)
        screen.apply(.print("menu"))

        let alternateSnapshot = screen.snapshot()

        #expect(alternateSnapshot.activeBuffer == .alternate)
        #expect(alternateSnapshot.plainTextLines.first == "menu")

        screen.apply(.exitAlternateScreen)
        let primarySnapshot = screen.snapshot()

        #expect(primarySnapshot.activeBuffer == .primary)
        #expect(primarySnapshot.plainTextLines.first == "shell")
    }

    @Test func screenModelErasesCurrentLine() {
        var screen = TerminalScreenModel(width: 20, height: 8)
        screen.apply(.print("abcdef"))
        screen.apply(.cursorPosition(row: 1, column: 1))
        screen.apply(.eraseInLine(mode: 2))

        let snapshot = screen.snapshot()

        #expect(snapshot.plainTextLines.first == "")
    }

    @Test func screenModelTreatsBareLineFeedAsNewTerminalLine() {
        var screen = TerminalScreenModel(width: 40, height: 8)
        screen.apply(.print("total 336"))
        screen.apply(.lineFeed)
        screen.apply(.print("drwxr-xr-x  15 feint  staff  480 Mar 17 10:52 ."))
        screen.apply(.lineFeed)
        screen.apply(.print("drwxr-xr-x  42 feint  staff 1344 Mar 17 10:21 .."))

        let snapshot = screen.snapshot()

        #expect(snapshot.plainTextLines[0] == "total 336")
        #expect(snapshot.plainTextLines[1] == "drwxr-xr-x  15 feint  staff  480 Mar 17 10:52 .")
        #expect(snapshot.plainTextLines[2] == "drwxr-xr-x  42 feint  staff 1344 Mar 17 10:21 ..")
        #expect(snapshot.cursor.row == 2)
    }
}