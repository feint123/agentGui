import Foundation

protocol GitCommandRunning {
    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult
}

@MainActor
protocol GitServicing {
    func repositorySnapshot(for workingDirectory: URL) async throws -> GitRepositorySnapshot
    func diff(for change: GitFileChange, staged: Bool, repositoryRoot: URL) async throws -> String
    func stage(path: String, repositoryRoot: URL) async throws
    func stageAll(repositoryRoot: URL) async throws
    func unstage(path: String, repositoryRoot: URL) async throws
    func discard(path: String, repositoryRoot: URL) async throws
    func cleanUntracked(path: String, repositoryRoot: URL) async throws
    func commit(message: String, repositoryRoot: URL) async throws
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
    case emptyCommitMessage
    case binaryDiffUnavailable

    var errorDescription: String? {
        switch self {
        case .notAGitRepository:
            return "当前目录不是 Git 仓库。"
        case .commandFailed(let message):
            return message
        case .parseFailed(let message):
            return message
        case .emptyCommitMessage:
            return "提交信息不能为空。"
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
            arguments: ["status", "--porcelain=v1", "--branch"],
            workingDirectory: repositoryRoot
        )
        try validate(result)

        do {
            return try GitStatusParser.parseStatus(result.stdout, repositoryRoot: repositoryRoot)
        } catch {
            throw GitServiceError.parseFailed("无法解析 Git 状态。")
        }
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

    func stage(path: String, repositoryRoot: URL) async throws {
        try await runMutation(["add", "--", path], repositoryRoot: repositoryRoot)
    }

    func stageAll(repositoryRoot: URL) async throws {
        try await runMutation(["add", "--all"], repositoryRoot: repositoryRoot)
    }

    func unstage(path: String, repositoryRoot: URL) async throws {
        try await runMutation(["restore", "--staged", "--", path], repositoryRoot: repositoryRoot)
    }

    func discard(path: String, repositoryRoot: URL) async throws {
        try await runMutation(["restore", "--", path], repositoryRoot: repositoryRoot)
    }

    func cleanUntracked(path: String, repositoryRoot: URL) async throws {
        try await runMutation(["clean", "-f", "--", path], repositoryRoot: repositoryRoot)
    }

    func commit(message: String, repositoryRoot: URL) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GitServiceError.emptyCommitMessage }
        try await runMutation(["commit", "-m", trimmed], repositoryRoot: repositoryRoot)
    }

    private func resolveRepositoryRoot(for workingDirectory: URL) async throws -> URL {
        let result = try await commandRunner.run(arguments: ["rev-parse", "--show-toplevel"], workingDirectory: workingDirectory)
        guard result.exitCode == 0 else {
            if result.stderr.localizedCaseInsensitiveContains("not a git repository") {
                throw GitServiceError.notAGitRepository
            }
            throw GitServiceError.commandFailed(errorMessage(from: result))
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
            throw GitServiceError.commandFailed(errorMessage(from: result))
        }
    }

    private func errorMessage(from result: GitCommandResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? (stdout.isEmpty ? "Git 命令执行失败。" : stdout) : stderr
    }
}

struct ProcessGitCommandRunner: GitCommandRunning {
    func run(arguments: [String], workingDirectory: URL) async throws -> GitCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
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
}