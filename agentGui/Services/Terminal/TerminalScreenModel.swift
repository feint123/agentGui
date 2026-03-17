import Foundation

struct TerminalScreenModel {
    private struct GraphicsState {
        var foreground: TerminalColor = .defaultForeground
        var background: TerminalColor = .defaultBackground
        var attributes: Set<TerminalTextAttribute> = []
    }

    private struct Buffer {
        var lines: [TerminalScreenLine]

        init(height: Int) {
            self.lines = Array(repeating: TerminalScreenLine(), count: max(height, 1))
        }
    }

    private(set) var width: Int
    private(set) var height: Int
    private var primaryBuffer: Buffer
    private var alternateBuffer: Buffer
    private(set) var activeBuffer: TerminalBufferKind = .primary
    private(set) var cursor = TerminalCursorSnapshot()
    private var graphicsState = GraphicsState()

    init(width: Int = 80, height: Int = 24) {
        self.width = width
        self.height = height
        self.primaryBuffer = Buffer(height: height)
        self.alternateBuffer = Buffer(height: height)
    }

    mutating func apply(_ event: TerminalVTEvent) {
        switch event {
        case .print(let text):
            write(text)
        case .carriageReturn:
            cursor.column = 0
        case .lineFeed:
            cursor.row = min(cursor.row + 1, height - 1)
            cursor.column = 0
            ensureLineExists(cursor.row)
        case .backspace:
            cursor.column = max(cursor.column - 1, 0)
        case .tab:
            cursor.column += 4
        case .cursorPosition(let row, let column):
            cursor.row = max(row - 1, 0)
            cursor.column = max(column - 1, 0)
            ensureLineExists(cursor.row)
        case .cursorUp(let count):
            cursor.row = max(cursor.row - count, 0)
        case .cursorDown(let count):
            cursor.row = min(cursor.row + count, height - 1)
            ensureLineExists(cursor.row)
        case .cursorForward(let count):
            cursor.column += count
        case .cursorBackward(let count):
            cursor.column = max(cursor.column - count, 0)
        case .eraseInLine(let mode):
            eraseLine(mode: mode)
        case .eraseInDisplay(let mode):
            eraseDisplay(mode: mode)
        case .setGraphicsRendition(let parameters):
            applyGraphicsRendition(parameters)
        case .enterAlternateScreen:
            activeBuffer = .alternate
            cursor = TerminalCursorSnapshot()
        case .exitAlternateScreen:
            activeBuffer = .primary
            cursor = TerminalCursorSnapshot(row: min(cursor.row, height - 1), column: 0)
        }
    }

    func snapshot() -> TerminalScreenSnapshot {
        let lines = activeBufferRef.lines
        return TerminalScreenSnapshot(
            lines: lines,
            plainTextLines: lines.map(\.plainText),
            activeBuffer: activeBuffer,
            cursor: cursor,
            width: width,
            height: height
        )
    }

    private var activeBufferRef: Buffer {
        get { activeBuffer == .primary ? primaryBuffer : alternateBuffer }
        set {
            if activeBuffer == .primary {
                primaryBuffer = newValue
            } else {
                alternateBuffer = newValue
            }
        }
    }

    private mutating func ensureLineExists(_ row: Int) {
        var buffer = activeBufferRef
        while buffer.lines.count <= row {
            buffer.lines.append(TerminalScreenLine())
        }
        activeBufferRef = buffer
    }

    private mutating func write(_ text: String) {
        for character in text {
            write(character: String(character))
        }
    }

    private mutating func write(character: String) {
        ensureLineExists(cursor.row)
        var buffer = activeBufferRef
        var line = buffer.lines[cursor.row]
        let displayWidth = character.terminalDisplayWidth

        ensureColumnExists(cursor.column + max(displayWidth, 1), line: &line)
        clearOverwrittenCells(at: cursor.column, displayWidth: displayWidth, line: &line)

        line.cells[cursor.column] = TerminalScreenCell(
            text: character,
            displayWidth: displayWidth,
            foreground: graphicsState.foreground,
            background: graphicsState.background,
            attributes: graphicsState.attributes,
            isContinuationCell: false
        )

        if displayWidth > 1 {
            for offset in 1..<displayWidth {
                ensureColumnExists(cursor.column + offset + 1, line: &line)
                line.cells[cursor.column + offset] = TerminalScreenCell(
                    text: "",
                    displayWidth: 0,
                    foreground: graphicsState.foreground,
                    background: graphicsState.background,
                    attributes: graphicsState.attributes,
                    isContinuationCell: true
                )
            }
        }

        buffer.lines[cursor.row] = line
        activeBufferRef = buffer
        cursor.column += displayWidth
    }

    private mutating func eraseLine(mode: Int) {
        ensureLineExists(cursor.row)
        var buffer = activeBufferRef
        var line = buffer.lines[cursor.row]

        switch mode {
        case 0:
            replaceLineRange(in: &line, range: cursor.column..<line.cells.count, with: [])
        case 1:
            replaceLineRange(in: &line, range: 0..<min(cursor.column + 1, line.cells.count), with: [])
        case 2:
            line = TerminalScreenLine()
            cursor.column = 0
        default:
            line = TerminalScreenLine()
        }

        buffer.lines[cursor.row] = line
        activeBufferRef = buffer
    }

    private mutating func eraseDisplay(mode: Int) {
        var buffer = activeBufferRef

        switch mode {
        case 0:
            var currentLine = buffer.lines[cursor.row]
            replaceLineRange(in: &currentLine, range: cursor.column..<currentLine.cells.count, with: [])
            buffer.lines[cursor.row] = currentLine
            if cursor.row + 1 < buffer.lines.count {
                for row in (cursor.row + 1)..<buffer.lines.count {
                    buffer.lines[row] = TerminalScreenLine()
                }
            }
        case 1:
            if cursor.row > 0 {
                for row in 0..<cursor.row {
                    buffer.lines[row] = TerminalScreenLine()
                }
            }
            var currentLine = buffer.lines[cursor.row]
            replaceLineRange(in: &currentLine, range: 0..<min(cursor.column + 1, currentLine.cells.count), with: [])
            buffer.lines[cursor.row] = currentLine
        default:
            buffer.lines = Array(repeating: TerminalScreenLine(), count: max(height, 1))
            cursor = TerminalCursorSnapshot()
        }

        activeBufferRef = buffer
    }

    private func replaceLineRange(in line: inout TerminalScreenLine, range: Range<Int>, with cells: [TerminalScreenCell]) {
        guard !line.cells.isEmpty else { return }
        let lower = min(max(range.lowerBound, 0), line.cells.count)
        let upper = min(max(range.upperBound, lower), line.cells.count)
        line.cells.replaceSubrange(lower..<upper, with: cells)
    }

    private func ensureColumnExists(_ targetCount: Int, line: inout TerminalScreenLine) {
        while line.cells.count < targetCount {
            line.cells.append(.blank)
        }
    }

    private func clearOverwrittenCells(at column: Int, displayWidth: Int, line: inout TerminalScreenLine) {
        if column < line.cells.count, line.cells[column].isContinuationCell {
            var start = column
            while start > 0, line.cells[start].isContinuationCell {
                start -= 1
            }
            line.cells[start] = .blank
            if start + 1 < line.cells.count, line.cells[start + 1].isContinuationCell {
                line.cells[start + 1] = .blank
            }
        }

        for offset in 0..<max(displayWidth, 1) {
            let index = column + offset
            guard index < line.cells.count else { continue }
            line.cells[index] = .blank
        }
    }

    private mutating func applyGraphicsRendition(_ parameters: [Int]) {
        let params = parameters.isEmpty ? [0] : parameters
        var index = 0

        while index < params.count {
            let parameter = params[index]

            switch parameter {
            case 0:
                graphicsState = GraphicsState()
            case 1:
                graphicsState.attributes.insert(.bold)
            case 2:
                graphicsState.attributes.insert(.dim)
            case 3:
                graphicsState.attributes.insert(.italic)
            case 4:
                graphicsState.attributes.insert(.underline)
            case 5:
                graphicsState.attributes.insert(.blink)
            case 7:
                graphicsState.attributes.insert(.inverse)
            case 8:
                graphicsState.attributes.insert(.hidden)
            case 9:
                graphicsState.attributes.insert(.strikethrough)
            case 22:
                graphicsState.attributes.remove(.bold)
                graphicsState.attributes.remove(.dim)
            case 23:
                graphicsState.attributes.remove(.italic)
            case 24:
                graphicsState.attributes.remove(.underline)
            case 25:
                graphicsState.attributes.remove(.blink)
            case 27:
                graphicsState.attributes.remove(.inverse)
            case 28:
                graphicsState.attributes.remove(.hidden)
            case 29:
                graphicsState.attributes.remove(.strikethrough)
            case 30...37:
                graphicsState.foreground = .ansi16(TerminalANSI16Color.foregroundCode(parameter))
            case 39:
                graphicsState.foreground = .defaultForeground
            case 40...47:
                graphicsState.background = .ansi16(TerminalANSI16Color.backgroundCode(parameter))
            case 49:
                graphicsState.background = .defaultBackground
            case 90...97:
                graphicsState.foreground = .ansi16(TerminalANSI16Color.brightForegroundCode(parameter))
            case 100...107:
                graphicsState.background = .ansi16(TerminalANSI16Color.brightBackgroundCode(parameter))
            case 38, 48:
                let isForeground = parameter == 38
                if index + 2 < params.count, params[index + 1] == 5 {
                    let color = TerminalColor.ansi256(params[index + 2])
                    if isForeground {
                        graphicsState.foreground = color
                    } else {
                        graphicsState.background = color
                    }
                    index += 2
                } else if index + 4 < params.count, params[index + 1] == 2 {
                    let color = TerminalColor.rgb(red: params[index + 2], green: params[index + 3], blue: params[index + 4])
                    if isForeground {
                        graphicsState.foreground = color
                    } else {
                        graphicsState.background = color
                    }
                    index += 4
                }
            default:
                break
            }

            index += 1
        }
    }
}

private extension TerminalANSI16Color {
    static func foregroundCode(_ code: Int) -> TerminalANSI16Color {
        [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white][max(0, min(code - 30, 7))]
    }

    static func backgroundCode(_ code: Int) -> TerminalANSI16Color {
        foregroundCode(code - 10 + 30)
    }

    static func brightForegroundCode(_ code: Int) -> TerminalANSI16Color {
        [.brightBlack, .brightRed, .brightGreen, .brightYellow, .brightBlue, .brightMagenta, .brightCyan, .brightWhite][max(0, min(code - 90, 7))]
    }

    static func brightBackgroundCode(_ code: Int) -> TerminalANSI16Color {
        brightForegroundCode(code - 10 + 90)
    }
}

private extension String {
    var terminalDisplayWidth: Int {
        guard let scalar = unicodeScalars.first else { return 1 }

        if scalar.properties.isEmojiPresentation || scalar.properties.generalCategory == .otherSymbol {
            return 2
        }

        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF:
            return 2
        default:
            return 1
        }
    }
}