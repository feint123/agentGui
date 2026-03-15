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

    static let readOnlySemanticDefaults = LSPServerCapabilityHints(
        supportsHover: true,
        supportsDefinition: true,
        supportsReferences: true,
        supportsDocumentSymbols: true,
        supportsWorkspaceSymbols: true,
        supportsDiagnostics: true
    )
}
