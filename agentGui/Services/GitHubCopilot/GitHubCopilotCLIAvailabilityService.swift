import Foundation

struct GitHubCopilotCLIAvailabilityStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case available
        case notInstalled
        case notAuthenticated
        case failed(String)
        case unknown
    }

    let kind: Kind
    let version: String?

    static let unknown = GitHubCopilotCLIAvailabilityStatus(kind: .unknown, version: nil)

    var summaryText: String {
        switch kind {
        case .available:
            if let version, !version.isEmpty {
                return "已检测到 GitHub Copilot CLI（\(version)）"
            }
            return "已检测到 GitHub Copilot CLI"
        case .notInstalled:
            return "未检测到 GitHub Copilot CLI 可执行文件"
        case .notAuthenticated:
            return "GitHub Copilot CLI 尚未认证"
        case .failed(let message):
            return "检测失败：\(message)"
        case .unknown:
            return "尚未检测 GitHub Copilot CLI 状态"
        }
    }
}

struct GitHubCopilotCLIAvailabilityService {
    nonisolated private let fileManager: FileManager
    nonisolated private let environment: [String: String]
    nonisolated private let loginShellPathResolver: ShellEnvironmentResolver.LoginShellPathResolver

    nonisolated init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPathResolver: @escaping ShellEnvironmentResolver.LoginShellPathResolver = ShellEnvironmentResolver.resolveLoginShellPath
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.loginShellPathResolver = loginShellPathResolver
    }

    func quickStatus(configuration: GitHubCopilotCLIConfiguration) -> GitHubCopilotCLIAvailabilityStatus {
        guard ShellEnvironmentResolver.resolveExecutableURL(
            command: configuration.executablePath,
            baseEnvironment: environment,
            fileManager: fileManager,
            loginShellPathResolver: loginShellPathResolver
        ) != nil else {
            return GitHubCopilotCLIAvailabilityStatus(kind: .notInstalled, version: nil)
        }

        return GitHubCopilotCLIAvailabilityStatus(kind: .available, version: nil)
    }

    func checkStatus(configuration: GitHubCopilotCLIConfiguration) async throws -> GitHubCopilotCLIAvailabilityStatus {
        await Task.detached(priority: .utility) {
            quickStatus(configuration: configuration)
        }.value
    }
}