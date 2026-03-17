import Foundation
import Testing
@testable import agentGui

struct TerminalScreenModelTests {

    @Test func screenSnapshotPreservesStyledCells() {
        let cell = TerminalScreenCell(
            text: "A",
            displayWidth: 1,
            foreground: .ansi256(196),
            background: .defaultBackground,
            attributes: [.bold, .underline],
            isContinuationCell: false
        )

        let snapshot = TerminalScreenSnapshot(
            lines: [.init(cells: [cell])],
            plainTextLines: ["A"],
            activeBuffer: .primary,
            cursor: .init(row: 0, column: 1),
            width: 80,
            height: 24
        )

        #expect(snapshot.lines[0].cells[0].foreground == .ansi256(196))
        #expect(snapshot.lines[0].cells[0].attributes.contains(.bold))
        #expect(snapshot.lines[0].cells[0].attributes.contains(.underline))
    }

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

    @Test func screenModelRewritesCurrentLineAfterCarriageReturn() {
        let parser = TerminalVTParser()
        var screen = TerminalScreenModel(width: 40, height: 8)

        for event in parser.parse("loading 10%\rloading 100%") {
            screen.apply(event)
        }

        let snapshot = screen.snapshot()

        #expect(snapshot.plainTextLines[0] == "loading 100%")
    }

    @Test func screenModelAppliesAnsiForegroundAndInverseAttributes() {
        let parser = TerminalVTParser()
        var screen = TerminalScreenModel(width: 20, height: 8)

        for event in parser.parse("\u{001B}[31;7mERR\u{001B}[0m") {
            screen.apply(event)
        }

        let snapshot = screen.snapshot()
        let firstCell = snapshot.lines[0].cells[0]

        #expect(firstCell.foreground == .ansi16(.red))
        #expect(firstCell.attributes.contains(.inverse))
        #expect(firstCell.text == "E")
        #expect(snapshot.plainTextLines[0] == "ERR")
    }

    @Test func screenModelMarksWideCharacterContinuationCells() {
        var screen = TerminalScreenModel(width: 20, height: 8)
        screen.apply(.print("你"))

        let snapshot = screen.snapshot()

        #expect(snapshot.lines[0].cells.count >= 2)
        #expect(snapshot.lines[0].cells[0].text == "你")
        #expect(snapshot.lines[0].cells[0].displayWidth == 2)
        #expect(snapshot.lines[0].cells[1].isContinuationCell)
    }
}