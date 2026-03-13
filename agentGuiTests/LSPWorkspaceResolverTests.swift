import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPWorkspaceResolverTests {

    @Test func resolverMatchesTypeScriptFilesByExtension() throws {
        let resolver = LSPWorkspaceResolver()
        let registry = try LSPServerRegistry(settings: .testFixture())

        let binding = try #require(
            resolver.resolve(
                filePath: "/repo/src/app.ts",
                workingDirectory: "/repo",
                registry: registry,
                settings: .testFixture()
            )
        )

        #expect(binding.serverID == "typescript-language-server")
        #expect(binding.workspaceRoot == "/repo")
        #expect(binding.languageID == "typescript")
        #expect(binding.isManual == false)
    }

    @Test func resolverMatchesPythonFilesByExtension() throws {
        let resolver = LSPWorkspaceResolver()
        let registry = try LSPServerRegistry(settings: .testFixture())

        let binding = try #require(
            resolver.resolve(
                filePath: "/repo/tools/script.py",
                workingDirectory: "/repo",
                registry: registry,
                settings: .testFixture()
            )
        )

        #expect(binding.serverID == "python-lsp")
        #expect(binding.languageID == "python")
    }

    @Test func manualBindingOverridesAutomaticResolution() throws {
        let resolver = LSPWorkspaceResolver()
        let settings = AppSettings.testFixture()
        settings.lspManualWorkspaceBindingsJSON = #"[{"workspaceRoot":"/repo","serverID":"python-lsp"}]"#
        let registry = try LSPServerRegistry(settings: settings)

        let binding = try #require(
            resolver.resolve(
                filePath: "/repo/src/app.ts",
                workingDirectory: "/repo",
                registry: registry,
                settings: settings
            )
        )

        #expect(binding.serverID == "python-lsp")
        #expect(binding.isManual == true)
    }

    @Test func resolverReturnsStructuredUnresolvedStateWhenNoProfileMatches() throws {
        let resolver = LSPWorkspaceResolver()
        let registry = try LSPServerRegistry(settings: .testFixture())

        let binding = resolver.resolve(
            filePath: "/repo/docs/spec.md",
            workingDirectory: "/repo",
            registry: registry,
            settings: .testFixture()
        )

        #expect(binding == nil)
        #expect(
            resolver.lastResolution?.status == .unresolved(reason: "No LSP server profile matched file path")
        )
    }

    @Test func swiftStubProfileDoesNotParticipateInAutomaticRouting() throws {
        let resolver = LSPWorkspaceResolver()
        let registry = try LSPServerRegistry(settings: .testFixture())

        let binding = resolver.resolve(
            filePath: "/repo/agentGui/AppView.swift",
            workingDirectory: "/repo",
            registry: registry,
            settings: .testFixture()
        )

        #expect(binding == nil)
        #expect(
            resolver.lastResolution?.status == .unresolved(reason: "No LSP server profile matched file path")
        )
    }
}