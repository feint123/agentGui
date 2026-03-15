import Testing
@testable import agentGui

@MainActor
struct LSPServiceStateStoreTests {
    @Test func stateStoreMergesProviderInstallationConfigurationAndRuntime() async throws {
        let settings = AppSettings.testFixture(
            installedDefinitions: [LSPProviderCatalog.builtInCatalog().provider(id: "gopls")!.defaultServerTemplate.replacingLaunchCommand("/usr/local/bin/gopls")]
        )
        settings.workingDirectory = "/repo"
        settings.lspInstalledProviders = [
            LSPInstalledProviderRecord(providerID: "gopls", executablePath: "/usr/local/bin/gopls")
        ]

        let harness = SharedLSPServerManagerHarness(settings: settings)
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "python-lsp")

        let store = LSPServiceStateStore(catalog: .builtInCatalog(), serverManager: manager)
        let states = store.states(settings: settings, workingDirectory: "/repo", selectedFilePath: nil)

        let python = try #require(states.first { $0.providerID == "python-lsp" })
        #expect(python.installationState == .installed)
        #expect(python.configurationState == .configured)
        #expect(python.runtimeStateSummary == "运行中")

        let go = try #require(states.first { $0.providerID == "gopls" })
        #expect(go.installationState == .installed)
        #expect(go.configurationState == .configured)
        #expect(go.runtimeStateSummary == "未启动")

        #expect(states.first { $0.providerID == "rust-analyzer" } == nil)
    }
}