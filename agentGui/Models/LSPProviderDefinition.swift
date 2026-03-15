import Foundation

enum LSPProviderInstallMethod: String, Codable, Hashable, Sendable {
    case builtIn
    case npmGlobal
    case homebrew
    case goTool
    case cargo
    case manual
}

struct LSPMigrationRecord: Codable, Hashable, Sendable {
    let legacyServerID: String
    let providerID: String
}

struct LSPProviderDefinition: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let supportedLanguageIDs: [String]
    let recommendedInstallMethod: LSPProviderInstallMethod
    let installPackageIdentifiers: [String]
    let isBuiltIn: Bool
    let legacyServerIDs: [String]
    let defaultServerTemplate: LSPServerDefinition

    init(
        id: String,
        displayName: String,
        supportedLanguageIDs: [String],
        recommendedInstallMethod: LSPProviderInstallMethod,
        installPackageIdentifiers: [String] = [],
        isBuiltIn: Bool,
        legacyServerIDs: [String] = [],
        defaultServerTemplate: LSPServerDefinition
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedLanguageIDs = supportedLanguageIDs
        self.recommendedInstallMethod = recommendedInstallMethod
        self.installPackageIdentifiers = installPackageIdentifiers
        self.isBuiltIn = isBuiltIn
        self.legacyServerIDs = legacyServerIDs
        self.defaultServerTemplate = defaultServerTemplate
    }
}