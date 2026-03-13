import Foundation
import OSLog

struct LSPProcessEnvironmentResolver {
    static func resolvedEnvironment(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        ShellEnvironmentResolver.resolvedEnvironment(baseEnvironment: baseEnvironment)
    }

    static func resolveExecutableURL(command: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if command.contains("/") {
            let url = URL(fileURLWithPath: command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let searchPath = environment["PATH"] ?? ""
        for candidatePath in searchPath.split(separator: ":").map(String.init) where !candidatePath.isEmpty {
            let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL
            }
        }
        return nil
    }
}

struct LSPRuntimeLogEntry: Equatable, Sendable {
    enum Level: String, Equatable, Sendable {
        case debug
        case info
        case error
    }

    let level: Level
    let message: String
}

protocol LSPManagedProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var terminationHandler: ((Int32) -> Void)? { get set }
    var standardOutputHandler: ((Data) -> Void)? { get set }
    var standardErrorHandler: ((Data) -> Void)? { get set }
    func start() throws
    func send(_ data: Data) throws
    func stop()
}

protocol LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess
}

enum LSPProcessState: Equatable {
    case idle
    case starting
    case running(processIdentifier: Int32)
    case failedToLaunch(reason: String)
    case crashed(reason: String, restartCount: Int)
    case stopped
}

@MainActor
final class LSPProcessSupervisor {
    private static let logger = Logger(subsystem: "com.agentgui", category: "LSP")
    private static let maxRetainedLogs = 40

    private let processLauncher: any LSPProcessLaunching
    private var currentProcess: (any LSPManagedProcess)?
    private var isStopping = false

    private(set) var state: LSPProcessState = .idle
    private(set) var restartCount = 0
    private(set) var recentLogs: [LSPRuntimeLogEntry] = []

    init(processLauncher: any LSPProcessLaunching) {
        self.processLauncher = processLauncher
    }

    @discardableResult
    func start(command: String, arguments: [String]) async throws -> any LSPManagedProcess {
        state = .starting
        isStopping = false
        record(.info, message: "Launching LSP process: \(renderCommand(command: command, arguments: arguments))")
        let resolvedEnvironment = LSPProcessEnvironmentResolver.resolvedEnvironment()
        if let path = resolvedEnvironment["PATH"] {
            record(.debug, message: "Resolved PATH: \(path)")
        }
        if let executableURL = LSPProcessEnvironmentResolver.resolveExecutableURL(command: command, environment: resolvedEnvironment) {
            record(.debug, message: "Resolved executable: \(executableURL.path)")
        }

        do {
            let process = try processLauncher.makeProcess(command: command, arguments: arguments)
            process.standardOutputHandler = { [weak self] data in
                guard let self else { return }
                Task { @MainActor in
                    self.record(.debug, message: "stdout \(self.summarize(data: data))")
                }
            }
            process.standardErrorHandler = { [weak self] data in
                guard let self else { return }
                Task { @MainActor in
                    self.record(.error, message: "stderr \(self.summarize(data: data))")
                }
            }
            process.terminationHandler = { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if self.isStopping {
                        self.record(.info, message: "LSP process stopped")
                        self.state = .stopped
                    } else {
                        self.restartCount += 1
                        self.record(.error, message: "LSP process crashed with status \(status)")
                        self.state = .crashed(reason: "Process exited with status \(status)", restartCount: self.restartCount)
                    }
                }
            }
            try process.start()
            currentProcess = process
            state = .running(processIdentifier: process.processIdentifier)
            record(.info, message: "LSP process started with pid \(process.processIdentifier)")
            return process
        } catch {
            let reason = String(describing: error).replacingOccurrences(of: "message(", with: "").replacingOccurrences(of: ")", with: "").replacingOccurrences(of: "\"", with: "")
            record(.error, message: "LSP process launch failed: \(reason)")
            state = .failedToLaunch(reason: reason)
            throw error
        }
    }

    func stop() async {
        isStopping = true
        record(.info, message: "Stopping LSP process")
        currentProcess?.stop()
        currentProcess = nil
        state = .stopped
    }

    func record(_ level: LSPRuntimeLogEntry.Level, message: String) {
        recentLogs.append(LSPRuntimeLogEntry(level: level, message: message))
        if recentLogs.count > Self.maxRetainedLogs {
            recentLogs.removeFirst(recentLogs.count - Self.maxRetainedLogs)
        }

        switch level {
        case .debug:
            Self.logger.debug("\(message)")
        case .info:
            Self.logger.info("\(message)")
        case .error:
            Self.logger.error("\(message)")
        }
    }

    private func renderCommand(command: String, arguments: [String]) -> String {
        ([command] + arguments).joined(separator: " ")
    }

    private func summarize(data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "<empty>"
        }
        return String(text.prefix(240))
    }
}

struct ProcessLSPProcessLauncher: LSPProcessLaunching {
    func makeProcess(command: String, arguments: [String]) throws -> any LSPManagedProcess {
        ProcessLSPManagedProcess(command: command, arguments: arguments)
    }
}

private final class ProcessLSPManagedProcess: LSPManagedProcess {
    enum StartError: Error, CustomStringConvertible {
        case executableNotFound(command: String, path: String)

        var description: String {
            switch self {
            case .executableNotFound(let command, let path):
                return "Unable to locate executable '\(command)' in PATH=\(path)"
            }
        }
    }

    var terminationHandler: ((Int32) -> Void)?
    var standardOutputHandler: ((Data) -> Void)?
    var standardErrorHandler: ((Data) -> Void)?

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    private let command: String
    private let arguments: [String]
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    // LSP needs a dedicated raw stdio channel with exact JSON-RPC framing.
    // BashSession is shell-oriented: it wraps commands, merges output into text transcripts,
    // and uses sentinels/timeouts for command completion, which would corrupt a persistent LSP stream.

    init(command: String, arguments: [String]) {
        self.command = command
        self.arguments = arguments
    }

    func start() throws {
        let environment = LSPProcessEnvironmentResolver.resolvedEnvironment()
        process.environment = environment

        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            if let executableURL = LSPProcessEnvironmentResolver.resolveExecutableURL(command: command, environment: environment) {
                process.executableURL = executableURL
                process.arguments = arguments
            } else {
                throw StartError.executableNotFound(command: command, path: environment["PATH"] ?? "")
            }
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.standardOutputHandler?(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.standardErrorHandler?(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.terminationHandler?(process.terminationStatus)
        }

        try process.run()
    }

    func send(_ data: Data) throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }
}