import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPServerRegistryTests {

    @Test func builtInProfilesDefaultToPythonOnly() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())

        let ids = Set(registry.allDefinitions().map(\.id))

        #expect(ids == ["python-lsp"])
    }

    @Test func builtInPythonProfileDeclaresLanguagesAndFileGlobs() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())
        let python = try #require(registry.definition(for: "python-lsp"))

        #expect(python.supportedLanguageIDs.contains("python"))
        #expect(python.defaultFileGlobs.contains("**/*.py"))
    }

    @Test func builtInPythonProfileDeclaresLaunchAndRootMarkers() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())
        let python = try #require(registry.definition(for: "python-lsp"))

        #expect(python.launchCommand == "pylsp")
        #expect(python.launchArguments.isEmpty)
        #expect(python.rootMarkers.contains("pyproject.toml"))
        #expect(python.rootMarkers.contains("requirements.txt"))
        #expect(python.rootMarkers.contains(".venv"))
        #expect(python.adapterKind == .generic)
    }

    @Test func installedDefinitionsAreMergedIntoRegistry() throws {
        let settings = AppSettings.testFixture()
        settings.lspInstalledServerDefinitions = [
            LSPServerDefinition(
                id: "gopls",
                displayName: "Go Language Server",
                launchCommand: "/usr/local/bin/gopls",
                launchArguments: [],
                supportedLanguageIDs: ["go"],
                defaultFileGlobs: ["**/*.go"],
                rootMarkers: ["go.mod"],
                adapterKind: .generic,
                providerID: "gopls",
                sourceKind: .installed
            )
        ]

        let registry = try LSPServerRegistry(settings: settings)

        #expect(registry.definition(for: "python-lsp") != nil)
        #expect(registry.definition(for: "gopls")?.sourceKind == .installed)
    }

    @Test func appSettingsExposeLSPDefaults() throws {
        let settings = AppSettings.testFixture()

        #expect(settings.enableLSPTools == false)
        #expect(settings.autoStartLSPServers == true)
        #expect(settings.lspDefaultRoutingMode == "automatic")
        #expect(settings.lspCustomServerProfilesJSON == "[]")
        #expect(settings.lspInstalledServerDefinitionsJSON == "[]")
    }

    @Test func duplicateCustomProfileIDsAreRejected() throws {
        let duplicateProfiles = [
            LSPServerDefinition(
                id: "duplicate-profile",
                displayName: "Duplicate Profile A",
                launchCommand: "pylsp",
                launchArguments: [],
                supportedLanguageIDs: ["python"],
                defaultFileGlobs: ["**/*.py"],
                rootMarkers: ["pyproject.toml"],
                adapterKind: .generic
            ),
            LSPServerDefinition(
                id: "duplicate-profile",
                displayName: "Duplicate Profile B",
                launchCommand: "pylsp",
                launchArguments: ["--stdio"],
                supportedLanguageIDs: ["python"],
                defaultFileGlobs: ["**/*.py"],
                rootMarkers: ["requirements.txt"],
                adapterKind: .generic
            )
        ]

        let settings = AppSettings.testFixture()
        settings.lspCustomServerProfilesJSON = try String(
            data: JSONEncoder().encode(duplicateProfiles),
            encoding: .utf8
        ) ?? "[]"

        #expect(throws: LSPServerRegistry.RegistryError.self) {
            _ = try LSPServerRegistry(settings: settings)
        }
    }
}