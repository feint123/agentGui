import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPManagementViewModelTests {
    @Test func managementViewModelMarksServiceAsRunningWhenRuntimeSessionExists() async throws {
        let settings = AppSettings.testFixture()
        settings.workingDirectory = "/repo"

        let harness = SharedLSPServerManagerHarness(settings: settings)
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "python-lsp")

        let store = LSPServiceStateStore(catalog: .builtInCatalog(), serverManager: manager)
        let viewModel = LSPManagementViewModel(
            settings: settings,
            serviceStateStore: store,
            installCoordinator: LSPInstallCoordinator(catalog: .builtInCatalog()),
            serverManager: manager,
            persistSettings: { _, mutation in
                mutation()
                return true
            }
        )

        let python = try #require(viewModel.services.first { $0.id == "python-lsp" })
        #expect(python.runtimeStatusText == "运行中")
        #expect(python.availableActions.contains(.stop))
        #expect(python.availableActions.contains(.restart))
    }

    @Test func restartActionRestartsExistingServiceSession() async throws {
        let settings = AppSettings.testFixture()
        settings.workingDirectory = "/repo"

        let harness = SharedLSPServerManagerHarness(settings: settings)
        let manager = harness.makeManager()
        _ = try await manager.startSession(workspaceRoot: "/repo", serverID: "python-lsp")

        let viewModel = LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(catalog: .builtInCatalog(), serverManager: manager),
            installCoordinator: LSPInstallCoordinator(catalog: .builtInCatalog()),
            serverManager: manager,
            persistSettings: { _, mutation in
                mutation()
                return true
            }
        )

        try await viewModel.perform(.restart, for: "python-lsp")

        #expect(harness.stopCallCount == 1)
        #expect(manager.state(for: "/repo", serverID: "python-lsp")?.summaryText.contains("running") == true)
    }

    @Test func managementViewModelSurfacesDetectedVersionAndRecentInstallLogs() async throws {
        let settings = AppSettings.testFixture()
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.successfulProbe(executablePath: "/tmp/.agentgui/lsp-server/bin/pylsp")],
            commandRunner: MockLSPInstallCommandRunner(results: [
                .success(stdout: "pylsp 1.2.3\n", stderr: "")
            ])
        )
        let result = await coordinator.install(providerID: "python-lsp")
        settings.lspInstalledProviders = [try #require(result.installedProviderRecord)]
        settings.lspInstalledServerDefinitions = [try #require(result.installedDefinition)]

        let viewModel = LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(catalog: .builtInCatalog(), serverManager: nil),
            installCoordinator: coordinator,
            serverManager: nil,
            persistSettings: { _, mutation in
                mutation()
                return true
            }
        )

        let python = try #require(viewModel.services.first { $0.id == "python-lsp" })
        #expect(python.versionText == "pylsp 1.2.3")
        #expect(python.installLogLines.contains { $0.contains("--version") })
    }

    @Test func managementViewModelSurfacesFailedInstallStateWithoutPersistence() async throws {
        let settings = AppSettings.testFixture()
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: MockLSPInstallCommandRunner(results: [
                .failure(stderr: "npm ERR! permission denied")
            ]),
            fileSystem: MockLSPInstallFileSystem(),
            installRoot: URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        )

        _ = await coordinator.install(providerID: "typescript-language-server")

        let viewModel = LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(catalog: .builtInCatalog(), serverManager: nil),
            installCoordinator: coordinator,
            serverManager: nil,
            persistSettings: { _, mutation in
                mutation()
                return true
            }
        )

        let typescript = try #require(viewModel.services.first { $0.id == "typescript-language-server" })
        #expect(typescript.installActivityText == "安装失败")
        #expect(typescript.detailText == "npm ERR! permission denied")
        #expect(typescript.installLogLines.contains { $0.contains("npm ERR! permission denied") })
    }
}