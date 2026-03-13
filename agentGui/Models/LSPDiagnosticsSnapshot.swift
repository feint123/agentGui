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

    init(message: String, severity: LSPDiagnosticSeverity) {
        self.message = message
        self.severity = severity
    }
}

struct LSPDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let workspaceRoot: String
    let uri: String
    let diagnostics: [LSPDiagnostic]
    let updatedAt: Date

    init(workspaceRoot: String, uri: String, diagnostics: [LSPDiagnostic], updatedAt: Date = Date()) {
        self.workspaceRoot = workspaceRoot
        self.uri = uri
        self.diagnostics = diagnostics
        self.updatedAt = updatedAt
    }
}