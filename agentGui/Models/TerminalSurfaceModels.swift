import Foundation

enum TerminalBufferKind: String, Codable, Equatable, Sendable {
    case primary
    case alternate
}

enum TerminalANSI16Color: String, Codable, CaseIterable, Equatable, Sendable {
    case black
    case red
    case green
    case yellow
    case blue
    case magenta
    case cyan
    case white
    case brightBlack
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightMagenta
    case brightCyan
    case brightWhite
}

enum TerminalColor: Codable, Equatable, Sendable {
    case defaultForeground
    case defaultBackground
    case ansi16(TerminalANSI16Color)
    case ansi256(Int)
    case rgb(red: Int, green: Int, blue: Int)
}

enum TerminalTextAttribute: String, Codable, CaseIterable, Hashable, Sendable {
    case bold
    case dim
    case italic
    case underline
    case strikethrough
    case inverse
    case blink
    case hidden
}

struct TerminalScreenCell: Codable, Equatable, Sendable {
    var text: String
    var displayWidth: Int
    var foreground: TerminalColor
    var background: TerminalColor
    var attributes: Set<TerminalTextAttribute>
    var isContinuationCell: Bool

    init(
        text: String,
        displayWidth: Int = 1,
        foreground: TerminalColor = .defaultForeground,
        background: TerminalColor = .defaultBackground,
        attributes: Set<TerminalTextAttribute> = [],
        isContinuationCell: Bool = false
    ) {
        self.text = text
        self.displayWidth = displayWidth
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.isContinuationCell = isContinuationCell
    }

    static let blank = TerminalScreenCell(text: " ")
}

struct TerminalScreenLine: Codable, Equatable, Sendable {
    var cells: [TerminalScreenCell]

    init(cells: [TerminalScreenCell] = []) {
        self.cells = cells
    }

    var plainText: String {
        cells
            .filter { !$0.isContinuationCell }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}"))
    }
}

struct TerminalCursorSnapshot: Codable, Equatable, Sendable {
    var row: Int
    var column: Int
    var isVisible: Bool

    init(row: Int = 0, column: Int = 0, isVisible: Bool = true) {
        self.row = row
        self.column = column
        self.isVisible = isVisible
    }
}

struct TerminalScreenSnapshot: Codable, Equatable, Sendable {
    var lines: [TerminalScreenLine]
    var plainTextLines: [String]
    var activeBuffer: TerminalBufferKind
    var cursor: TerminalCursorSnapshot
    var width: Int
    var height: Int

    init(
        lines: [TerminalScreenLine] = [],
        plainTextLines: [String],
        activeBuffer: TerminalBufferKind,
        cursor: TerminalCursorSnapshot,
        width: Int,
        height: Int
    ) {
        let resolvedLines = lines.isEmpty
            ? plainTextLines.map { line in
                TerminalScreenLine(cells: line.map { TerminalScreenCell(text: String($0)) })
            }
            : lines

        self.lines = resolvedLines
        self.plainTextLines = plainTextLines
        self.activeBuffer = activeBuffer
        self.cursor = cursor
        self.width = width
        self.height = height
    }
}

enum TerminalVTEvent: Equatable, Sendable {
    case print(String)
    case carriageReturn
    case lineFeed
    case backspace
    case tab
    case cursorPosition(row: Int, column: Int)
    case cursorUp(Int)
    case cursorDown(Int)
    case cursorForward(Int)
    case cursorBackward(Int)
    case eraseInLine(mode: Int)
    case eraseInDisplay(mode: Int)
    case setGraphicsRendition([Int])
    case enterAlternateScreen
    case exitAlternateScreen
}

enum TerminalSelectionMode: String, Codable, Equatable, Sendable {
    case none
    case singleSelect
    case multiSelect
    case textInput
    case unknown
}

enum TerminalInteractionPhase: String, Codable, Equatable, Sendable {
    case planning
    case autoExecuting
    case awaitingApproval
    case userTakeover
}

enum TerminalKey: String, Codable, Equatable, Sendable {
    case enter
    case space
    case tab
    case up
    case down
    case left
    case right
}

struct TerminalVisibleOption: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var label: String
    var isSelected: Bool
    var isFocused: Bool

    init(label: String, isSelected: Bool, isFocused: Bool) {
        self.id = label
        self.label = label
        self.isSelected = isSelected
        self.isFocused = isFocused
    }
}

struct TerminalSurfaceSnapshot: Codable, Equatable, Sendable {
    var plainTextFrame: String
    var rawANSISnippet: String
    var visibleOptions: [TerminalVisibleOption]
    var focusedOptionIndex: Int?
    var selectionMode: TerminalSelectionMode
    var isAlternateScreen: Bool
    var cursorRow: Int?
    var cursorColumn: Int?
    var inputHint: String?

    init(
        plainTextFrame: String,
        rawANSISnippet: String,
        visibleOptions: [TerminalVisibleOption] = [],
        focusedOptionIndex: Int? = nil,
        selectionMode: TerminalSelectionMode = .unknown,
        isAlternateScreen: Bool = false,
        cursorRow: Int? = nil,
        cursorColumn: Int? = nil,
        inputHint: String? = nil
    ) {
        self.plainTextFrame = plainTextFrame
        self.rawANSISnippet = rawANSISnippet
        self.visibleOptions = visibleOptions
        self.focusedOptionIndex = focusedOptionIndex
        self.selectionMode = selectionMode
        self.isAlternateScreen = isAlternateScreen
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.inputHint = inputHint
    }
}

struct TerminalInteractionObservation: Codable, Equatable, Sendable {
    var taskId: String
    var command: String
    var surface: TerminalSurfaceSnapshot
    var recentOutput: String
}

enum TerminalInteractionAction: Codable, Equatable, Sendable {
    case key(TerminalKey)
    case text(String)
    case wait(milliseconds: Int)
    case signal(TerminalSignal)

    var isKeyboardAction: Bool {
        switch self {
        case .key:
            return true
        default:
            return false
        }
    }
}

struct TerminalInteractionPlan: Codable, Equatable, Sendable {
    var interactionType: String
    var intentSummary: String
    var confidence: Double
    var nextActions: [TerminalInteractionAction]
    var requiresUserConfirmation: Bool
    var reasoningSummary: String
}