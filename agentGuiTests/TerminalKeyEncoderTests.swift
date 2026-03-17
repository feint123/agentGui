import Foundation
import Testing
@testable import agentGui

struct TerminalKeyEncoderTests {

    @Test func keyEncoderMapsEnterAndSpace() async throws {
        let encoder = TerminalKeyEncoder()

        #expect(encoder.encode(.enter) == "\r")
        #expect(encoder.encode(.space) == " ")
    }

    @Test func keyEncoderMapsArrowKeysToAnsiSequences() async throws {
        let encoder = TerminalKeyEncoder()

        #expect(encoder.encode(.up) == "\u{1B}[A")
        #expect(encoder.encode(.down) == "\u{1B}[B")
        #expect(encoder.encode(.left) == "\u{1B}[D")
        #expect(encoder.encode(.right) == "\u{1B}[C")
    }

    @Test func keyEncoderMapsTab() async throws {
        let encoder = TerminalKeyEncoder()

        #expect(encoder.encode(.tab) == "\t")
    }
}