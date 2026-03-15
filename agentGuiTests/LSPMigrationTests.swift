import Foundation
import Testing
@testable import agentGui

struct LSPMigrationTests {
    @Test func migrationMapsLegacyBuiltInServerIDsToProviders() {
        let catalog = LSPProviderCatalog.builtInCatalog()

        #expect(catalog.providerID(forLegacyServerID: "typescript-language-server") == "typescript-language-server")
        #expect(catalog.providerID(forLegacyServerID: "python-lsp") == "python-lsp")
        #expect(catalog.providerID(forLegacyServerID: "swift-sourcekit-lsp") == nil)
    }

    @Test func migratingLegacyDefinitionsPreservesCustomProfiles() throws {
        let settings = AppSettings.testFixture()
        let customProfiles = [
            LSPServerDefinition(
                id: "custom-rust-analyzer",
                displayName: "Rust Analyzer",
                launchCommand: "rust-analyzer",
                launchArguments: [],
                supportedLanguageIDs: ["rust"],
                defaultFileGlobs: ["**/*.rs"],
                rootMarkers: ["Cargo.toml"],
                adapterKind: .generic
            )
        ]
        settings.lspCustomServerProfilesJSON = try String(data: JSONEncoder().encode(customProfiles), encoding: .utf8) ?? "[]"
        settings.lspInstalledServerDefinitionsJSON = try String(data: JSONEncoder().encode([
            LSPServerDefinition(
                id: "typescript-language-server",
                displayName: "TypeScript Language Server",
                launchCommand: "typescript-language-server",
                launchArguments: ["--stdio"],
                supportedLanguageIDs: ["typescript", "javascript"],
                defaultFileGlobs: ["**/*.{ts,tsx,js,jsx}"],
                rootMarkers: ["package.json"],
                adapterKind: .generic,
                providerID: "typescript-language-server",
                sourceKind: .installed
            )
        ]), encoding: .utf8) ?? "[]"

        let migrated = LSPProviderCatalog.builtInCatalog().migrateLegacyBuiltInServerDefinitions(in: settings)

        #expect(migrated.contains { $0.providerID == "typescript-language-server" })
        #expect(settings.lspCustomServerProfiles.map(\.id) == ["custom-rust-analyzer"])
    }
}