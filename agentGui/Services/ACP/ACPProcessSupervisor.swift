import Foundation

enum ACPProcessSupervisorError: Error, LocalizedError {
    case executableNotFound(command: String, path: String)
    case standardInputUnavailable
    case standardOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command, let path):
            return "Unable to locate executable '\(command)' in PATH=\(path)"
        case .standardInputUnavailable:
            return "ACP process standard input pipe is unavailable"
        case .standardOutputUnavailable:
            return "ACP process standard output pipe is unavailable"
        }
    }
}

final class ACPProcessSupervisor {
    private(set) var process: Process?

    func start(
        command: String,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        standardErrorHandler: ((String) -> Void)? = nil
    ) throws -> ACPTransport {
        let environment = ShellEnvironmentResolver.resolvedEnvironment(environmentOverrides: environmentOverrides)
        let process = Process()

        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
        } else if let executableURL = resolveExecutableURL(command: command, environment: environment) {
            process.executableURL = executableURL
        } else {
            throw ACPProcessSupervisorError.executableNotFound(command: command, path: environment["PATH"] ?? "")
        }

        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let standardErrorHandler {
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                standardErrorHandler(String(decoding: data, as: UTF8.self))
            }
        }

        try process.run()
        self.process = process

        return ACPTransport(
            reader: stdoutPipe.fileHandleForReading,
            writer: stdinPipe.fileHandleForWriting
        )
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func resolveExecutableURL(command: String, environment: [String: String]) -> URL? {
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