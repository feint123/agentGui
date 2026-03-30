import Foundation

struct CodeEditorSemanticPosition: Equatable, Sendable {
    let line: Int
    let column: Int
    let utf16Offset: Int
    let version: Int
}

enum CodeEditorSemanticIntent: Equatable, Sendable {
    case requestDefinition(CodeEditorSemanticPosition)
    case requestReferences(CodeEditorSemanticPosition)
    case requestHover(CodeEditorSemanticPosition)
    case cancelHover
}

struct CodeEditorRevealRequest: Equatable, Sendable, Identifiable {
    enum Reason: Equatable, Sendable {
        case definition
        case reference
        case documentSymbol
    }

    let id: UUID
    let fileURL: URL
    let line: Int
    let column: Int
    let reason: Reason

    init(
        id: UUID = UUID(),
        fileURL: URL,
        line: Int,
        column: Int,
        reason: Reason
    ) {
        self.id = id
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.reason = reason
    }
}

struct CodeEditorHoverPresentation: Equatable, Sendable {
    let position: CodeEditorSemanticPosition
    let markdown: String
}

struct CodeEditorReferencePresentation: Equatable, Sendable, Identifiable {
    struct Item: Equatable, Sendable, Identifiable {
        let id: UUID
        let fileURL: URL
        let line: Int
        let column: Int
        let title: String
        let subtitle: String

        init(
            id: UUID = UUID(),
            fileURL: URL,
            line: Int,
            column: Int,
            title: String,
            subtitle: String
        ) {
            self.id = id
            self.fileURL = fileURL
            self.line = line
            self.column = column
            self.title = title
            self.subtitle = subtitle
        }
    }

    let id: UUID
    let queryPosition: CodeEditorSemanticPosition
    let items: [Item]

    init(
        id: UUID = UUID(),
        queryPosition: CodeEditorSemanticPosition,
        items: [Item]
    ) {
        self.id = id
        self.queryPosition = queryPosition
        self.items = items
    }
}