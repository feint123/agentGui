import Darwin
import Foundation

nonisolated struct PtyProcessResult: Equatable, Sendable {
    let pid: Int32
    let exitCode: Int32
    let rawOutput: String
    let output: String
}

nonisolated enum PtyProcessControllerError: Error {
    case openPtyFailed(Int32)
    case launchFailed
    case writeFailed(Int32)
    case signalFailed(Int32)
}

nonisolated final class PtyProcessController {
    private static let defaultRows: UInt16 = 24
    private static let defaultColumns: UInt16 = 80

    private enum LaunchConfiguration {
        case shell(command: String, shell: String)
        case executable(command: String, args: [String])
    }

    private let launchConfiguration: LaunchConfiguration
    private let workingDirectory: String?
    private let environment: [String: String]
    private let process = Process()
    private let outputLock = NSLock()
    private var outputData = Data()
    private var masterFileHandle: FileHandle?
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var hasStarted = false

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    init(
        command: String,
        shell: String = "/bin/zsh",
        workingDirectory: String?,
        environment: [String: String]
    ) throws {
        self.launchConfiguration = .shell(command: command, shell: shell)
        self.workingDirectory = workingDirectory
        self.environment = environment

        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(
            ws_row: Self.defaultRows,
            ws_col: Self.defaultColumns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if openpty(&master, &slave, nil, nil, &windowSize) != 0 {
            throw PtyProcessControllerError.openPtyFailed(errno)
        }

        self.masterFD = master
        self.slaveFD = slave
        self.masterFileHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
    }

    init(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) throws {
        self.launchConfiguration = .executable(command: executable, args: arguments)
        self.workingDirectory = workingDirectory
        self.environment = environment

        var master: Int32 = -1
        var slave: Int32 = -1
        var windowSize = winsize(
            ws_row: Self.defaultRows,
            ws_col: Self.defaultColumns,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if openpty(&master, &slave, nil, nil, &windowSize) != 0 {
            throw PtyProcessControllerError.openPtyFailed(errno)
        }

        self.masterFD = master
        self.slaveFD = slave
        self.masterFileHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
    }

    deinit {
        masterFileHandle?.readabilityHandler = nil
        if masterFD >= 0 { close(masterFD) }
        if slaveFD >= 0 { close(slaveFD) }
    }

    func runUntilExit() async throws -> PtyProcessResult {
        try start()
        return try await waitForExit()
    }

    func start() throws {
        guard !hasStarted else { return }
        guard let masterFileHandle else {
            throw PtyProcessControllerError.launchFailed
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        switch launchConfiguration {
        case .shell(let command, let shell):
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", command]
        case .executable(let command, let args):
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        }
        process.environment = ShellEnvironmentResolver.resolvedEnvironment(baseEnvironment: environment)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        masterFileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.outputLock.lock()
            self.outputData.append(data)
            self.outputLock.unlock()
        }

        try process.run()
        hasStarted = true
        close(slaveFD)
        slaveFD = -1
    }

    func waitForExit() async throws -> PtyProcessResult {
        if process.isRunning {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        masterFileHandle?.readabilityHandler = nil
        if let remainder = try masterFileHandle?.readToEnd(), !remainder.isEmpty {
            outputLock.lock()
            outputData.append(remainder)
            outputLock.unlock()
        }

        let rawOutput = rawOutput()
        let output = normalizedOutput(rawOutput)
        return PtyProcessResult(
            pid: process.processIdentifier,
            exitCode: process.terminationStatus,
            rawOutput: rawOutput,
            output: output
        )
    }

    func sendInput(_ input: String) throws {
        guard masterFD >= 0 else {
            throw PtyProcessControllerError.writeFailed(EBADF)
        }

        let data = Array(input.utf8)
        let written = data.withUnsafeBytes { bytes in
            write(masterFD, bytes.baseAddress, bytes.count)
        }

        if written < 0 {
            throw PtyProcessControllerError.writeFailed(errno)
        }
    }

    func interrupt() throws {
        try sendSignal(SIGINT)
    }

    func terminate(force: Bool = false) throws {
        try sendSignal(force ? SIGKILL : SIGTERM)
    }

    private func rawOutput() -> String {
        outputLock.lock()
        let data = outputData
        outputLock.unlock()

        return String(decoding: data, as: UTF8.self)
    }

    private func normalizedOutput(_ rawOutput: String? = nil) -> String {
        (rawOutput ?? self.rawOutput())
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func currentOutput() -> String {
        normalizedOutput()
    }

    func currentRawOutput() -> String {
        rawOutput()
    }

    private func sendSignal(_ signal: Int32) throws {
        guard process.processIdentifier > 0 else {
            throw PtyProcessControllerError.signalFailed(ESRCH)
        }

        if kill(process.processIdentifier, signal) != 0 {
            throw PtyProcessControllerError.signalFailed(errno)
        }
    }
}