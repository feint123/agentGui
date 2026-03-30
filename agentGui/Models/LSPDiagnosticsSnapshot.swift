import Foundation

enum LSPDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
    case information
    case hint
}

struct LSPDiagnostic: Codable, Equatable, Sendable {
    let message: String
    let severity: LSPDiagnosticSeverity
    let source: String?
    let line: Int?
    let character: Int?
    let endLine: Int?
    let endCharacter: Int?

    init(
        message: String,
        severity: LSPDiagnosticSeverity,
        source: String? = nil,
        line: Int? = nil,
        character: Int? = nil,
        endLine: Int? = nil,
        endCharacter: Int? = nil
    ) {
        self.message = message
        self.severity = severity
        self.source = source
        self.line = line
        self.character = character
        self.endLine = endLine
        self.endCharacter = endCharacter
    }
}

struct LSPDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let workspaceRoot: String
    let uri: String
    let diagnostics: [LSPDiagnostic]
    let documentVersion: Int?
    let updatedAt: Date

    init(
        workspaceRoot: String,
        uri: String,
        diagnostics: [LSPDiagnostic],
        documentVersion: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.workspaceRoot = workspaceRoot
        self.uri = uri
        self.diagnostics = diagnostics
        self.documentVersion = documentVersion
        self.updatedAt = updatedAt
    }
}