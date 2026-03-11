import Foundation

protocol GitCommandRunning {
    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult
}

@MainActor
protocol GitServicing {
    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot
    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference]
    func switchBranch(to branchName: String, repositoryRoot: URL) async throws
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String
}

struct GitCommandResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum GitServiceError: LocalizedError, Equatable {
    case notAGitRepository
    case commandFailed(String)
    case parseFailed(String)
    case binaryDiffUnavailable

    var errorDescription: String? {
        switch self {
        case .notAGitRepository:
            return "当前目录不是 Git 仓库。"
        case .commandFailed(let message):
            return message
        case .parseFailed(let message):
            return message
        case .binaryDiffUnavailable:
            return "该文件的 diff 无法以文本形式显示。"
        }
    }
}

@MainActor
final class GitService: GitServicing {
    private let commandRunner: GitCommandRunning

    init(commandRunner: GitCommandRunning = ProcessGitCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot {
        let repositoryRoot = try await resolveRepositoryRoot(for: workingDirectory)
        let result = try await commandRunner.run(
            arguments: ["-c", "core.quotepath=false", "status", "--porcelain=v1", "--branch"],
            workingDirectory: repositoryRoot
        )
        try validate(result)

        do {
            return try GitStatusParser.parseStatus(result.stdout, repositoryRoot: repositoryRoot)
        } catch {
            throw GitServiceError.parseFailed("无法解析 Git 状态。")
        }
    }

    func listBranches(repositoryRoot: URL) async throws -> [GitBranchReference] {
        let result = try await commandRunner.run(arguments: ["branch", "--list"], workingDirectory: repositoryRoot)
        try validate(result)

        let lines = result.stdout
            .split(whereSeparator: \ .isNewline)
            .map(String.init)

        return lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("*") {
                let branchName = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                return GitBranchReference(name: branchName, isCurrent: true)
            }

            return GitBranchReference(name: trimmed, isCurrent: false)
        }
    }

    func switchBranch(to branchName: String, repositoryRoot: URL) async throws {
        try await runMutation(["switch", branchName], repositoryRoot: repositoryRoot)
    }

    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String {
        let arguments = staged
            ? ["diff", "--cached", "--", change.relativePath]
            : ["diff", "--", change.relativePath]
        let result = try await commandRunner.run(arguments: arguments, workingDirectory: repositoryRoot)
        try validate(result)

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("Binary files") {
            throw GitServiceError.binaryDiffUnavailable
        }
        return output
    }

    private func resolveRepositoryRoot(for workingDirectory: URL) async throws -> URL {
        let result = try await commandRunner.run(arguments: ["rev-parse", "--show-toplevel"], workingDirectory: workingDirectory)
        guard result.exitCode == 0 else {
            if result.stderr.localizedCaseInsensitiveContains("not a git repository") {
                throw GitServiceError.notAGitRepository
            }
            throw GitServiceError.commandFailed(userFacingErrorMessage(from: result))
        }

        let rootPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else {
            throw GitServiceError.parseFailed("无法确定 Git 仓库根目录。")
        }
        return URL(fileURLWithPath: rootPath)
    }

    private func runMutation(_ arguments: [String], repositoryRoot: URL) async throws {
        let result = try await commandRunner.run(arguments: arguments, workingDirectory: repositoryRoot)
        try validate(result)
    }

    private func validate(_ result: GitCommandResult) throws {
        guard result.exitCode == 0 else {
            if result.stderr.localizedCaseInsensitiveContains("not a git repository") {
                throw GitServiceError.notAGitRepository
            }
            throw GitServiceError.commandFailed(userFacingErrorMessage(from: result))
        }
    }

    private func userFacingErrorMessage(from result: GitCommandResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? (stdout.isEmpty ? "Git 命令执行失败。" : stdout) : stderr
    }
}

struct ProcessGitCommandRunner: GitCommandRunning {
    private static let gitExecutablePath = resolveGitExecutablePath()

    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: Self.gitExecutablePath)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { process in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: GitCommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func resolveGitExecutablePath() -> String {
        let fileManager = FileManager.default
        let candidatePaths = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ]

        return candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) ?? "/usr/bin/git"
    }
}