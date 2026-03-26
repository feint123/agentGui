import Foundation

nonisolated enum TerminalShellIntegrationEvent: Equatable, Sendable {
    case promptStart
    case promptEnd
    case commandStart
    case commandFinished(exitCode: Int32?)
    case commandLine(String)
    case property(name: String, value: String)
}

nonisolated struct TerminalShellIntegrationParser {
    func parse(_ output: String) -> [TerminalShellIntegrationEvent] {
        let sequences = extractSequences(from: output)
        return sequences.compactMap(parseSequence)
    }

    private func extractSequences(from output: String) -> [String] {
        let scalars = Array(output.unicodeScalars)
        var sequences: [String] = []
        var index = 0

        while index + 4 < scalars.count {
            if scalars[index] == "\u{001B}",
               scalars[index + 1] == "]",
               scalars[index + 2] == "6",
               scalars[index + 3] == "3",
               scalars[index + 4] == "3" {
                var cursor = index + 5
                if cursor < scalars.count, scalars[cursor] == ";" {
                    cursor += 1
                }

                var buffer = ""
                while cursor < scalars.count, scalars[cursor] != "\u{0007}" {
                    buffer.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                sequences.append(buffer)
                index = cursor + 1
                continue
            }

            index += 1
        }

        return sequences
    }

    private func parseSequence(_ sequence: String) -> TerminalShellIntegrationEvent? {
        if sequence == "A" {
            return .promptStart
        }

        if sequence == "B" {
            return .promptEnd
        }

        if sequence == "C" {
            return .commandStart
        }

        if sequence.hasPrefix("D") {
            let parts = sequence.split(separator: ";", omittingEmptySubsequences: false)
            let exitCode = parts.count > 1 ? Int32(parts[1]) : nil
            return .commandFinished(exitCode: exitCode)
        }

        if sequence.hasPrefix("E;") {
            return .commandLine(String(sequence.dropFirst(2)))
        }

        if sequence.hasPrefix("P;") {
            let propertyText = String(sequence.dropFirst(2))
            let parts = propertyText.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .property(name: parts[0], value: parts[1])
        }

        return nil
    }
}