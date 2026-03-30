import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorSemanticQueryTests {
    @Test
    func documentSymbolsParseNestedDocumentSymbolPayload() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")

        let symbols = try await manager.documentSymbols(
            workspaceRoot: "/tmp",
            serverID: "python-lsp",
            uri: "file:///tmp/Sample.py"
        )

        #expect(symbols.count == 1)
        #expect(symbols.first?.name == "Demo")
        #expect(symbols.first?.line == 0)
        #expect(symbols.first?.children.first?.name == "inner")
        #expect(symbols.first?.children.first?.line == 1)
    }

    @Test
    func documentSymbolsParseSymbolInformationPayload() async throws {
        let harness = SharedLSPServerManagerHarness(settings: .lspFixture(installedProviderIDs: ["python-lsp"]))
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")

        let symbols = try await manager.documentSymbols(
            workspaceRoot: "/tmp",
            serverID: "python-lsp",
            uri: "file:///tmp/FlatSample.py"
        )

        #expect(symbols.map(\.name) == ["FlatDemo", "helper"])
        #expect(symbols.allSatisfy { $0.children.isEmpty })
        #expect(symbols.map(\.line) == [2, 8])
    }

    @Test
    func toolFacadeDocumentSymbolsReturnsFormattedSymbolList() async throws {
        let settings = AppSettings.lspFixture(installedProviderIDs: ["python-lsp"])
        let harness = SharedLSPServerManagerHarness(settings: settings)
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/tmp", serverID: "python-lsp")
        let registry = try LSPServerRegistry(settings: settings)
        let facade = LSPToolFacade(registry: registry, serverManager: manager)

        let result = try await facade.documentSymbols(
            workspaceRoot: "/tmp",
            serverID: "python-lsp",
            uri: "file:///tmp/Sample.py"
        )

        #expect(result.contains("Demo"))
        #expect(result.contains("inner"))
        #expect(result.contains("file:///tmp/Sample.py") == false)
        #expect(result.contains("not implemented yet") == false)
    }
}