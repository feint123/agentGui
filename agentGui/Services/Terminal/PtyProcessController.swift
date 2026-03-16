import Darwin
import Foundation

struct PtyProcessResult: Equatable, Sendable {
    let pid: Int32
    let exitCode: Int32
    let output: String
}

enum PtyProcessControllerError: Error {
    case openPtyFailed(Int32)
    case launchFailed
    case writeFailed(Int32)
    case signalFailed(Int32)
}

final class PtyProcessController {
    private let command: String
    private let shell: String
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
        self.command = command
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.environment = environment

        var master: Int32 = -1
        var slave: Int32 = -1
        if openpty(&master, &slave, nil, nil, nil) != 0 {
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
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
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

        let output = normalizedOutput()
        return PtyProcessResult(
            pid: process.processIdentifier,
            exitCode: process.terminationStatus,
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

    private func normalizedOutput() -> String {
        outputLock.lock()
        let data = outputData
        outputLock.unlock()

        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func currentOutput() -> String {
        normalizedOutput()
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