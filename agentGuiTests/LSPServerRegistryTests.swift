import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPServerRegistryTests {

    @Test func builtInProfilesIncludeTypeScriptAndPython() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())

        let ids = Set(registry.allDefinitions().map(\.id))

        #expect(ids.contains("typescript-language-server"))
        #expect(ids.contains("python-lsp"))
    }

    @Test func builtInProfilesDeclareLanguagesAndFileGlobs() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())
        let typescript = try #require(registry.definition(for: "typescript-language-server"))
        let python = try #require(registry.definition(for: "python-lsp"))

        #expect(typescript.supportedLanguageIDs.contains("typescript"))
        #expect(typescript.supportedLanguageIDs.contains("javascript"))
        #expect(typescript.defaultFileGlobs.contains("**/*.{ts,tsx,js,jsx}"))

        #expect(python.supportedLanguageIDs.contains("python"))
        #expect(python.defaultFileGlobs.contains("**/*.py"))
    }

    @Test func builtInTypeScriptProfileDeclaresLaunchAndRootMarkers() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())
        let typescript = try #require(registry.definition(for: "typescript-language-server"))

        #expect(typescript.launchCommand == "typescript-language-server")
        #expect(typescript.launchArguments == ["--stdio"])
        #expect(typescript.rootMarkers.contains("package.json"))
        #expect(typescript.rootMarkers.contains("tsconfig.json"))
        #expect(typescript.rootMarkers.contains("jsconfig.json"))
        #expect(typescript.adapterKind == .generic)
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

    @Test func registryIncludesSwiftSourceKitStubProfile() throws {
        let registry = try LSPServerRegistry(settings: .testFixture())
        let swift = try #require(registry.definition(for: "swift-sourcekit-lsp"))

        #expect(swift.launchCommand == "xcrun")
        #expect(swift.launchArguments == ["sourcekit-lsp"])
        #expect(swift.adapterKind == .sourcekit)
        #expect(swift.rootMarkers.contains("*.xcodeproj"))
        #expect(swift.rootMarkers.contains("Package.swift"))
    }

    @Test func appSettingsExposeLSPDefaults() throws {
        let settings = AppSettings.testFixture()

        #expect(settings.enableLSPTools == false)
        #expect(settings.autoStartLSPServers == true)
        #expect(settings.lspDefaultRoutingMode == "automatic")
        #expect(settings.lspCustomServerProfilesJSON == "[]")
    }

    @Test func duplicateCustomProfileIDsAreRejected() throws {
        let duplicateProfiles = [
            LSPServerDefinition(
                id: "typescript-language-server",
                displayName: "Duplicate TS",
                launchCommand: "typescript-language-server",
                launchArguments: ["--stdio"],
                supportedLanguageIDs: ["typescript"],
                defaultFileGlobs: ["**/*.ts"],
                rootMarkers: ["package.json"],
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