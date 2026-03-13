import Foundation

struct LSPProjectDiagnosticsSummary: Equatable, Sendable {
    struct DiagnosticItem: Equatable, Sendable {
        let uri: String
        let message: String
        let severity: LSPDiagnosticSeverity
        let source: String?
        let line: Int?
        let character: Int?

        init(
            uri: String,
            message: String,
            severity: LSPDiagnosticSeverity,
            source: String? = nil,
            line: Int? = nil,
            character: Int? = nil
        ) {
            self.uri = uri
            self.message = message
            self.severity = severity
            self.source = source
            self.line = line
            self.character = character
        }
    }

    let workspaceRoot: String
    let filesWithDiagnostics: Int
    let errorCount: Int
    let warningCount: Int
    let informationCount: Int
    let hintCount: Int
    let updatedAt: Date
    let recentDiagnostics: [DiagnosticItem]
}