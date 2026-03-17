import Foundation

struct TerminalVTParser {
    func parse(_ text: String) -> [TerminalVTEvent] {
        let scalars = Array(text.unicodeScalars)
        var events: [TerminalVTEvent] = []
        var printBuffer = ""
        var index = 0

        func flushPrintBuffer() {
            guard !printBuffer.isEmpty else { return }
            events.append(.print(printBuffer))
            printBuffer = ""
        }

        while index < scalars.count {
            let scalar = scalars[index]

            switch scalar {
            case "\u{001B}":
                flushPrintBuffer()
                if index + 1 < scalars.count {
                    let next = scalars[index + 1]
                    if next == "[" {
                        index = consumeCSI(from: index + 2, in: scalars, events: &events)
                    } else if next == "]" {
                        index = consumeOSC(from: index + 2, in: scalars)
                    }
                }
            case "\r":
                flushPrintBuffer()
                events.append(.carriageReturn)
            case "\n":
                flushPrintBuffer()
                events.append(.lineFeed)
            case "\t":
                flushPrintBuffer()
                events.append(.tab)
            case "\u{0008}":
                flushPrintBuffer()
                events.append(.backspace)
            default:
                printBuffer.unicodeScalars.append(scalar)
            }

            index += 1
        }

        flushPrintBuffer()
        return events
    }

    private func consumeCSI(from startIndex: Int, in scalars: [UnicodeScalar], events: inout [TerminalVTEvent]) -> Int {
        var index = startIndex
        var parameterText = ""

        while index < scalars.count {
            let current = scalars[index]
            if current.isASCII, CharacterSet.letters.union(CharacterSet(charactersIn: "@`~")).contains(current) {
                let final = Character(current)
                events.append(contentsOf: parseCSI(parameterText: parameterText, final: final))
                return index
            }
            parameterText.unicodeScalars.append(current)
            index += 1
        }

        return max(scalars.count - 1, 0)
    }

    private func consumeOSC(from startIndex: Int, in scalars: [UnicodeScalar]) -> Int {
        var index = startIndex

        while index < scalars.count {
            let current = scalars[index]
            if current == "\u{0007}" {
                return index
            }

            if current == "\u{001B}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                return index + 1
            }

            index += 1
        }

        return max(scalars.count - 1, 0)
    }

    private func parseCSI(parameterText: String, final: Character) -> [TerminalVTEvent] {
        switch final {
        case "H":
            let parameters = parseParameters(parameterText)
            let row = parameters.first ?? 1
            let column = parameters.dropFirst().first ?? 1
            return [.cursorPosition(row: row, column: column)]
        case "A":
            return [.cursorUp(parseParameters(parameterText).first ?? 1)]
        case "B":
            return [.cursorDown(parseParameters(parameterText).first ?? 1)]
        case "C":
            return [.cursorForward(parseParameters(parameterText).first ?? 1)]
        case "D":
            return [.cursorBackward(parseParameters(parameterText).first ?? 1)]
        case "J":
            return [.eraseInDisplay(mode: parseParameters(parameterText).first ?? 0)]
        case "K":
            return [.eraseInLine(mode: parseParameters(parameterText).first ?? 0)]
        case "m":
            return [.setGraphicsRendition(parseParameters(parameterText, defaultValue: 0))]
        case "h":
            return parameterText == "?1049" ? [.enterAlternateScreen] : []
        case "l":
            return parameterText == "?1049" ? [.exitAlternateScreen] : []
        default:
            return []
        }
    }

    private func parseParameters(_ text: String, defaultValue: Int? = nil) -> [Int] {
        if text.isEmpty {
            return defaultValue.map { [$0] } ?? []
        }

        return text
            .split(separator: ";", omittingEmptySubsequences: false)
            .compactMap { part in
                if part.isEmpty {
                    return defaultValue
                }
                let normalized = part.hasPrefix("?") ? String(part.dropFirst()) : String(part)
                return Int(normalized)
            }
    }
}