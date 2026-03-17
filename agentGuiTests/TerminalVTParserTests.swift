import Foundation
import Testing
@testable import agentGui

struct TerminalVTParserTests {

    @Test func parserIgnoresOperatingSystemCommandSequences() throws {
        let events = TerminalVTParser().parse("\u{001B}]9;4;0;\u{0007}ok\u{001B}]0;\u{0007}")

        #expect(events == [.print("ok")])
    }

    @Test func parserIgnoresOperatingSystemCommandSequencesTerminatedByStringTerminator() throws {
        let events = TerminalVTParser().parse("\u{001B}]133;A\u{001B}\\ready")

        #expect(events == [.print("ready")])
    }

    @Test func parserEmitsAlternateScreenEnterAndExit() throws {
        let events = TerminalVTParser().parse("\u{001B}[?1049hhello\u{001B}[?1049l")

        #expect(events.contains(.enterAlternateScreen))
        #expect(events.contains(.print("hello")))
        #expect(events.contains(.exitAlternateScreen))
    }

    @Test func parserEmitsCursorAndEraseEvents() throws {
        let events = TerminalVTParser().parse("\u{001B}[3;5H\u{001B}[2K\u{001B}[J")

        #expect(events.contains(.cursorPosition(row: 3, column: 5)))
        #expect(events.contains(.eraseInLine(mode: 2)))
        #expect(events.contains(.eraseInDisplay(mode: 0)))
    }

    @Test func parserEmitsGraphicsRenditionParameters() throws {
        let events = TerminalVTParser().parse("\u{001B}[31;7mERR\u{001B}[0m")

        #expect(events.contains(.setGraphicsRendition([31, 7])))
        #expect(events.contains(.print("ERR")))
        #expect(events.contains(.setGraphicsRendition([0])))
    }

    @Test func parserEmitsControlCharacterEvents() throws {
        let events = TerminalVTParser().parse("a\rb\nc\t\u{0008}")

        #expect(events.contains(.print("a")))
        #expect(events.contains(.carriageReturn))
        #expect(events.contains(.lineFeed))
        #expect(events.contains(.tab))
        #expect(events.contains(.backspace))
    }
}