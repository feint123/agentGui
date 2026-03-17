import Foundation
import Testing
@testable import agentGui

struct TerminalShellIntegrationParserTests {

    @Test func parserReadsWorkingDirectoryProperty() async throws {
        let parser = TerminalShellIntegrationParser()
        let events = parser.parse("\u{001B}]633;P;Cwd=/tmp/demo\u{07}")

        #expect(events.contains(.property(name: "Cwd", value: "/tmp/demo")))
    }

    @Test func parserReadsExplicitCommandLine() async throws {
        let parser = TerminalShellIntegrationParser()
        let events = parser.parse("\u{001B}]633;E;npm create vue@latest vue3-demo\u{07}")

        #expect(events.contains(.commandLine("npm create vue@latest vue3-demo")))
    }

    @Test func parserReadsCommandLifecycleMarkers() async throws {
        let parser = TerminalShellIntegrationParser()
        let events = parser.parse("\u{001B}]633;A\u{07}\u{001B}]633;C\u{07}\u{001B}]633;D;0\u{07}")

        #expect(events.contains(.promptStart))
        #expect(events.contains(.commandStart))
        #expect(events.contains(.commandFinished(exitCode: 0)))
    }
}