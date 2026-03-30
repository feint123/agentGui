import Foundation

struct LSPDocumentSymbol: Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let detail: String?
    let kind: Int
    let line: Int
    let character: Int
    let endLine: Int?
    let endCharacter: Int?
    let children: [LSPDocumentSymbol]

    init(
        id: UUID = UUID(),
        name: String,
        detail: String?,
        kind: Int,
        line: Int,
        character: Int,
        endLine: Int? = nil,
        endCharacter: Int? = nil,
        children: [LSPDocumentSymbol] = []
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.line = line
        self.character = character
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.children = children
    }
}