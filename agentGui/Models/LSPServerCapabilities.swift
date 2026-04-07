import Foundation

enum LSPAdapterKind: String, Codable, Sendable {
    case generic
}

enum LSPTransportKind: String, Codable, Sendable {
    case stdio
}

enum LSPHealthCheckMode: String, Codable, Sendable {
    case processExit
    case initializeHandshake
}

struct LSPServerCapabilityHints: Codable, Hashable, Sendable {
    var supportsHover: Bool
    var supportsDefinition: Bool
    var supportsReferences: Bool
    var supportsDocumentSymbols: Bool
    var supportsWorkspaceSymbols: Bool
    var supportsDiagnostics: Bool

    // — L-4 Completion —
    var supportsCompletion: Bool = false
    var completionTriggerCharacters: [String] = []

    // — L-5 Signature Help —
    var supportsSignatureHelp: Bool = false
    var signatureHelpTriggerCharacters: [String] = []
    var signatureHelpRetriggerCharacters: [String] = []

    // — L-6 Code Actions —
    var supportsCodeActions: Bool = false

    // — L-7 Formatting —
    var supportsDocumentFormatting: Bool = false
    var supportsRangeFormatting: Bool = false
    var supportsOnTypeFormatting: Bool = false
    var onTypeFormattingTriggerCharacters: [String] = []

    // — L-8 Rename —
    var supportsRename: Bool = false
    var supportsPrepareRename: Bool = false

    // — L-9 Document Highlights —
    var supportsDocumentHighlights: Bool = false

    // — Declaration / TypeDefinition / Implementation —
    var supportsDeclaration: Bool = false
    var supportsTypeDefinition: Bool = false
    var supportsImplementation: Bool = false

    // — Folding Range —
    var supportsFoldingRange: Bool = false

    // — Semantic Tokens —
    var supportsSemanticTokens: Bool = false

    // — Inlay Hints —
    var supportsInlayHints: Bool = false

    static let readOnlySemanticDefaults = LSPServerCapabilityHints(
        supportsHover: true,
        supportsDefinition: true,
        supportsReferences: true,
        supportsDocumentSymbols: true,
        supportsWorkspaceSymbols: true,
        supportsDiagnostics: true
    )
}

extension LSPServerCapabilityHints {
    static let allDisabled = LSPServerCapabilityHints(
        supportsHover: false,
        supportsDefinition: false,
        supportsReferences: false,
        supportsDocumentSymbols: false,
        supportsWorkspaceSymbols: false,
        supportsDiagnostics: false
    )
}
