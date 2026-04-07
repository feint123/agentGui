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

/// 面包屑路径中的单个 symbol 节点，携带同级 sibling 列表用于 Menu 下拉。
struct CodeEditorSymbolPathNode: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let detail: String?
    let symbolKind: Int         // LSP SymbolKind integer
    let line: Int               // 1-based
    let revealRequest: CodeEditorRevealRequest
    /// 当前 symbol 在其父节点中的所有同级 symbol（含自身），供面包屑下拉菜单使用。
    let siblings: [CodeEditorSymbolSiblingItem]

    init(
        id: UUID = UUID(),
        name: String,
        detail: String?,
        symbolKind: Int,
        line: Int,
        revealRequest: CodeEditorRevealRequest,
        siblings: [CodeEditorSymbolSiblingItem]
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbolKind = symbolKind
        self.line = line
        self.revealRequest = revealRequest
        self.siblings = siblings
    }
}

/// 面包屑下拉菜单中一个同级 symbol 的极简表示。
struct CodeEditorSymbolSiblingItem: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let symbolKind: Int
    let revealRequest: CodeEditorRevealRequest

    init(
        id: UUID = UUID(),
        name: String,
        symbolKind: Int,
        revealRequest: CodeEditorRevealRequest
    ) {
        self.id = id
        self.name = name
        self.symbolKind = symbolKind
        self.revealRequest = revealRequest
    }
}