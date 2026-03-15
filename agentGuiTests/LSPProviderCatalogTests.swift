import Testing
@testable import agentGui

struct LSPProviderCatalogTests {
    @Test func pythonProviderIsBuiltInButTypeScriptIsInstallable() {
        let catalog = LSPProviderCatalog.builtInCatalog()

        #expect(catalog.provider(id: "python-lsp")?.isBuiltIn == true)
        #expect(catalog.provider(id: "typescript-language-server")?.isBuiltIn == false)
    }

    @Test func builtInCatalogIncludesMainstreamInstallableProviders() {
        let catalog = LSPProviderCatalog.builtInCatalog()
        let ids = Set(catalog.allProviders().map(\.id))

        #expect(ids.contains("python-lsp"))
        #expect(ids.contains("typescript-language-server"))
        #expect(ids.contains("clangd"))
        #expect(ids.contains("gopls"))
        #expect(!ids.contains("rust-analyzer"))
        #expect(!ids.contains("jdtls"))
        #expect(!ids.contains("swift-sourcekit-lsp"))
    }

    @Test func providerCarriesRecommendedInstallMethodAndDefaultTemplate() throws {
        let catalog = LSPProviderCatalog.builtInCatalog()
        let provider = try #require(catalog.provider(id: "gopls"))

        #expect(provider.recommendedInstallMethod == .goTool)
        #expect(provider.supportedLanguageIDs == ["go"])
        #expect(provider.defaultServerTemplate.id == "gopls")
        #expect(provider.defaultServerTemplate.providerID == "gopls")
    }
}