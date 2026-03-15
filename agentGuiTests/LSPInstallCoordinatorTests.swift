import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPInstallCoordinatorTests {
    @Test func installCoordinatorReturnsStructuredFailureWhenExecutableCannotBeResolved() async throws {
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.failingExecutableProbe]
        )

        let result = await coordinator.install(providerID: "clangd")

        #expect(result.status == .failed)
        #expect(result.recoverySuggestion == .recheckPath)
        #expect(result.installedDefinition == nil)
    }

    @Test func installCoordinatorReturnsInstalledDefinitionWhenProbeSucceeds() async throws {
        let runner = MockLSPInstallCommandRunner(results: [
            .success(stdout: "pylsp 1.2.3\n", stderr: "")
        ])
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.successfulProbe(executablePath: "/usr/local/bin/pylsp")],
            commandRunner: runner
        )

        let result = await coordinator.install(providerID: "python-lsp")

        #expect(result.status == .installed)
        #expect(result.installedDefinition?.launchCommand == "/usr/local/bin/pylsp")
        #expect(result.installedDefinition?.providerID == "python-lsp")
        #expect(result.installedProviderRecord?.version == "pylsp 1.2.3")
        #expect(coordinator.activity(providerID: "python-lsp")?.detectedVersion == "pylsp 1.2.3")
    }

    @Test func managedInstallUsesNpmPrefixUnderAgentGuiDirectory() async throws {
        let runner = MockLSPInstallCommandRunner(results: [
            .success(stdout: "", stderr: ""),
            .success(stdout: "typescript-language-server 4.1.0\n", stderr: "")
        ])
        let fileSystem = MockLSPInstallFileSystem()
        let root = URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: runner,
            fileSystem: fileSystem,
            installRoot: root
        )

        let result = await coordinator.install(providerID: "typescript-language-server")

        #expect(result.status == .installed)
        #expect(result.executablePath == "/tmp/.agentgui/lsp-server/bin/typescript-language-server")
        #expect(result.installedProviderRecord?.version == "typescript-language-server 4.1.0")
        #expect(runner.commands.count == 2)
        #expect(runner.commands.first?.executable == "npm")
        #expect(runner.commands.first?.arguments.contains("--prefix") == true)
        #expect(runner.commands.first?.arguments.contains("/tmp/.agentgui/lsp-server/providers/typescript-language-server/npm-prefix") == true)
        #expect(runner.commands.first?.arguments.contains("typescript-language-server") == true)
        #expect(runner.commands.first?.arguments.contains("typescript") == true)
        #expect(fileSystem.writtenExecutableFiles.keys.contains("/tmp/.agentgui/lsp-server/bin/typescript-language-server"))
    }

    @Test func managedInstallUsesGoInstallWithManagedGOBIN() async throws {
        let runner = MockLSPInstallCommandRunner(results: [
            .success(stdout: "", stderr: ""),
            .success(stdout: "gopls v0.17.1\n", stderr: "")
        ])
        let fileSystem = MockLSPInstallFileSystem(existingPaths: [
            "/tmp/.agentgui/lsp-server/bin/gopls"
        ])
        let root = URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: runner,
            fileSystem: fileSystem,
            installRoot: root
        )

        let result = await coordinator.install(providerID: "gopls")

        #expect(result.status == .installed)
        #expect(result.executablePath == "/tmp/.agentgui/lsp-server/bin/gopls")
        #expect(result.installedProviderRecord?.version == "gopls v0.17.1")
        #expect(runner.commands.count == 2)
        #expect(runner.commands.first?.executable == "go")
        #expect(runner.commands.first?.arguments == ["install", "golang.org/x/tools/gopls@latest"])
        #expect(runner.commands.first?.environment["GOBIN"] == "/tmp/.agentgui/lsp-server/bin")
    }

    @Test func managedInstallUsesBrewAndLinksIntoManagedBinDirectory() async throws {
        let runner = MockLSPInstallCommandRunner(results: [
            .success(stdout: "", stderr: ""),
            .success(stdout: "/opt/homebrew/opt/llvm\n", stderr: ""),
            .success(stdout: "clangd version 19.0.0\n", stderr: "")
        ])
        let fileSystem = MockLSPInstallFileSystem(existingPaths: [
            "/opt/homebrew/opt/llvm/bin/clangd"
        ])
        let root = URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: runner,
            fileSystem: fileSystem,
            installRoot: root
        )

        let result = await coordinator.install(providerID: "clangd")

        #expect(result.status == .installed)
        #expect(result.installedProviderRecord?.version == "clangd version 19.0.0")
        #expect(runner.commands.count == 3)
        #expect(runner.commands[0].executable == "brew")
        #expect(runner.commands[0].arguments == ["install", "llvm"])
        #expect(runner.commands[1].executable == "brew")
        #expect(runner.commands[1].arguments == ["--prefix", "llvm"])
        #expect(fileSystem.symlinkOperations.contains {
            $0.path == "/tmp/.agentgui/lsp-server/bin/clangd"
            && $0.destination == "/opt/homebrew/opt/llvm/bin/clangd"
        })
        #expect(result.executablePath == "/tmp/.agentgui/lsp-server/bin/clangd")
    }

    @Test func installCoordinatorPublishesInFlightProgressAndCompletionSnapshot() async throws {
        let runner = BlockingLSPInstallCommandRunner(result: .success(stdout: "typescript-language-server 4.1.0\n", stderr: ""))
        let fileSystem = MockLSPInstallFileSystem()
        let root = URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: runner,
            fileSystem: fileSystem,
            installRoot: root
        )

        let task = Task { await coordinator.install(providerID: "typescript-language-server") }
        await runner.awaitFirstCommand()

        let installing = try #require(coordinator.activity(providerID: "typescript-language-server"))
        #expect(installing.phase == .installing)
        #expect(installing.progressMessage?.contains("npm") == true)
        #expect(installing.logs.isEmpty == false)

        runner.resumeInstallAndVersionProbe()
        let result = await task.value
        let completed = try #require(coordinator.activity(providerID: "typescript-language-server"))

        #expect(result.status == .installed)
        #expect(completed.phase == .completed)
        #expect(completed.detectedVersion == "typescript-language-server 4.1.0")
    }

    @Test func failedInstallRetainsFailureMessageAndRecentLogsForUI() async throws {
        let runner = MockLSPInstallCommandRunner(results: [
            .failure(stderr: "npm ERR! permission denied")
        ])
        let coordinator = LSPInstallCoordinator(
            catalog: .builtInCatalog(),
            strategies: [.managedInstall],
            commandRunner: runner,
            fileSystem: MockLSPInstallFileSystem(),
            installRoot: URL(fileURLWithPath: "/tmp/.agentgui/lsp-server", isDirectory: true)
        )

        let result = await coordinator.install(providerID: "typescript-language-server")
        let snapshot = try #require(coordinator.activity(providerID: "typescript-language-server"))

        #expect(result.status == .failed)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.lastFailure == "npm ERR! permission denied")
        #expect(snapshot.logs.contains { $0.message.contains("npm ERR! permission denied") })
    }
}

final class MockLSPInstallCommandRunner: LSPInstallCommandRunning {
    struct ResultItem {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        static func success(stdout: String, stderr: String) -> ResultItem {
            ResultItem(exitCode: 0, stdout: stdout, stderr: stderr)
        }

        static func failure(stderr: String) -> ResultItem {
            ResultItem(exitCode: 1, stdout: "", stderr: stderr)
        }
    }

    private(set) var commands: [LSPInstallCommand] = []
    private let queuedResults: [ResultItem]

    init(results: [ResultItem]) {
        self.queuedResults = results
    }

    func run(_ command: LSPInstallCommand) async -> LSPInstallCommandResult {
        commands.append(command)
        let result = queuedResults[min(commands.count - 1, queuedResults.count - 1)]
        return LSPInstallCommandResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }
}

final class BlockingLSPInstallCommandRunner: LSPInstallCommandRunning {
    private let versionResult: LSPInstallCommandResult
    private var installContinuation: CheckedContinuation<Void, Never>?
    private var firstCommandContinuation: CheckedContinuation<Void, Never>?
    private(set) var commands: [LSPInstallCommand] = []

    init(result: MockLSPInstallCommandRunner.ResultItem) {
        self.versionResult = LSPInstallCommandResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    func run(_ command: LSPInstallCommand) async -> LSPInstallCommandResult {
        commands.append(command)

        if commands.count == 1 {
            firstCommandContinuation?.resume()
            await withCheckedContinuation { continuation in
                installContinuation = continuation
            }
            return LSPInstallCommandResult(exitCode: 0, stdout: "", stderr: "")
        }

        return versionResult
    }

    func awaitFirstCommand() async {
        if !commands.isEmpty {
            return
        }

        await withCheckedContinuation { continuation in
            firstCommandContinuation = continuation
        }
    }

    func resumeInstallAndVersionProbe() {
        installContinuation?.resume()
        installContinuation = nil
    }
}

final class MockLSPInstallFileSystem: LSPInstallFileManaging {
    struct SymlinkOperation: Equatable {
        let path: String
        let destination: String
    }

    private(set) var createdDirectories: [String] = []
    private(set) var writtenExecutableFiles: [String: String] = [:]
    private(set) var symlinkOperations: [SymlinkOperation] = []
    private var existingPaths: Set<String>

    init(existingPaths: [String] = []) {
        self.existingPaths = Set(existingPaths)
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url.path)
        existingPaths.insert(url.path)
    }

    func writeExecutableFile(at url: URL, contents: String) throws {
        writtenExecutableFiles[url.path] = contents
        existingPaths.insert(url.path)
    }

    func createOrReplaceSymlink(at url: URL, destination: URL) throws {
        symlinkOperations.append(SymlinkOperation(path: url.path, destination: destination.path))
        existingPaths.insert(url.path)
    }

    func fileExists(at url: URL) -> Bool {
        existingPaths.contains(url.path)
    }
}