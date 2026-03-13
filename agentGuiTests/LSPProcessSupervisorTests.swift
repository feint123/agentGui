import Foundation
import Testing
@testable import agentGui

@MainActor
struct LSPProcessSupervisorTests {

    @Test func startTransitionsToRunningWhenLaunchSucceeds() async throws {
        let launcher = FakeLSPProcessLauncher(mode: .success(processID: 42))
        let supervisor = LSPProcessSupervisor(processLauncher: launcher)

        try await supervisor.start(command: "typescript-language-server", arguments: ["--stdio"])

        #expect(supervisor.state == .running(processIdentifier: 42))
    }

    @Test func startTransitionsToFailedToLaunchWhenLauncherThrows() async {
        let launcher = FakeLSPProcessLauncher(mode: .failure(message: "missing binary"))
        let supervisor = LSPProcessSupervisor(processLauncher: launcher)

        await #expect(throws: FakeLSPProcessLauncher.LaunchError.self) {
            try await supervisor.start(command: "typescript-language-server", arguments: ["--stdio"])
        }

        #expect(supervisor.state == .failedToLaunch(reason: "missing binary"))
    }

    @Test func unexpectedTerminationTransitionsToCrashedAndIncrementsRestartCount() async throws {
        let launcher = FakeLSPProcessLauncher(mode: .success(processID: 7))
        let supervisor = LSPProcessSupervisor(processLauncher: launcher)

        try await supervisor.start(command: "pylsp", arguments: [])
        launcher.lastProcess?.simulateExit(status: 9)
        await Task.yield()

        #expect(supervisor.state == .crashed(reason: "Process exited with status 9", restartCount: 1))
        #expect(supervisor.restartCount == 1)
    }

    @Test func manualStopDoesNotCountAsCrash() async throws {
        let launcher = FakeLSPProcessLauncher(mode: .success(processID: 11))
        let supervisor = LSPProcessSupervisor(processLauncher: launcher)

        try await supervisor.start(command: "pylsp", arguments: [])
        await supervisor.stop()

        #expect(supervisor.state == .stopped)
        #expect(supervisor.restartCount == 0)
    }

    @Test func standardErrorIsCapturedInRecentLogs() async throws {
        let launcher = FakeLSPProcessLauncher(mode: .success(processID: 17))
        let supervisor = LSPProcessSupervisor(processLauncher: launcher)

        try await supervisor.start(command: "pylsp", arguments: [])
        launcher.lastProcess?.emitStandardError("ModuleNotFoundError: pylsp_plugins")
        await Task.yield()

        #expect(supervisor.recentLogs.contains { $0.message.contains("ModuleNotFoundError: pylsp_plugins") })
    }

    @Test func executableResolverFindsBinaryInProvidedPath() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let executableURL = tempDirectory.appendingPathComponent("pylsp")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/zsh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let resolved = LSPProcessEnvironmentResolver.resolveExecutableURL(
            command: "pylsp",
            environment: ["PATH": tempDirectory.path]
        )

        #expect(resolved?.path == executableURL.path)
    }
}

private final class FakeLSPProcessLauncher: LSPProcessLaunching {
    enum Mode {
        case success(processID: Int32)
        case failure(message: String)
    }

    enum LaunchError: Error, Equatable {
        case message(String)
    }

    let mode: Mode
    private(set) var lastProcess: FakeLSPManagedProcess?

    init(mode: Mode) {
        self.mode = mode
    }

    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        switch mode {
        case .success(let processID):
            let process = FakeLSPManagedProcess(processIdentifier: processID)
            lastProcess = process
            return process
        case .failure(let message):
            throw LaunchError.message(message)
        }
    }
}

private final class FakeLSPManagedProcess: LSPManagedProcess {
    let processIdentifier: Int32
    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?
    private(set) var didStart = false
    private(set) var didStop = false

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    func start() throws {
        didStart = true
    }

    func send(_ data: Data) throws {}

    func stop() {
        didStop = true
    }

    func simulateExit(status: Int32) {
        terminationHandler?(status)
    }

    func emitStandardError(_ text: String) {
        standardErrorHandler?(Data(text.utf8))
    }
}