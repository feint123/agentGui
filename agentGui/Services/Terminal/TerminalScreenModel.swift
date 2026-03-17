import Foundation

struct TerminalScreenModel {
    private struct Buffer {
        var lines: [String]

        init(height: Int) {
            self.lines = Array(repeating: "", count: max(height, 1))
        }
    }

    private(set) var width: Int
    private(set) var height: Int
    private var primaryBuffer: Buffer
    private var alternateBuffer: Buffer
    private(set) var activeBuffer: TerminalBufferKind = .primary
    private(set) var cursor = TerminalCursorSnapshot()

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
        case .setGraphicsRendition:
            break
        case .enterAlternateScreen:
            activeBuffer = .alternate
            cursor = TerminalCursorSnapshot()
        case .exitAlternateScreen:
            activeBuffer = .primary
            cursor = TerminalCursorSnapshot(row: min(cursor.row, height - 1), column: 0)
        }
    }

    func snapshot() -> TerminalScreenSnapshot {
        let lines = activeBufferRef.lines.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}")) }
        return TerminalScreenSnapshot(
            plainTextLines: lines,
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
            buffer.lines.append("")
        }
        activeBufferRef = buffer
    }

    private mutating func write(_ text: String) {
        ensureLineExists(cursor.row)
        var buffer = activeBufferRef
        var line = buffer.lines[cursor.row]

        if cursor.column > line.count {
            line += String(repeating: " ", count: cursor.column - line.count)
        }

        let insertionIndex = line.index(line.startIndex, offsetBy: min(cursor.column, line.count))
        line.insert(contentsOf: text, at: insertionIndex)
        buffer.lines[cursor.row] = line
        activeBufferRef = buffer
        cursor.column += text.count
    }

    private mutating func eraseLine(mode: Int) {
        ensureLineExists(cursor.row)
        var buffer = activeBufferRef
        switch mode {
        case 2:
            buffer.lines[cursor.row] = ""
            cursor.column = 0
        default:
            buffer.lines[cursor.row] = ""
        }
        activeBufferRef = buffer
    }

    private mutating func eraseDisplay(mode: Int) {
        var buffer = activeBufferRef
        switch mode {
        default:
            buffer.lines = Array(repeating: "", count: max(height, 1))
            cursor = TerminalCursorSnapshot()
        }
        activeBufferRef = buffer
    }
}