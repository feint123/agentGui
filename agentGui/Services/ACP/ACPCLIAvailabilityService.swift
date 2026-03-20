import Foundation

struct ACPCLIAvailabilityStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case available
        case notInstalled
        case notAuthenticated
        case failed(String)
        case unknown
    }

    let kind: Kind
    let version: String?
    let displayName: String

    init(kind: Kind, version: String?, displayName: String = "CLI") {
        self.kind = kind
        self.version = version
        self.displayName = displayName
    }

    static let unknown = ACPCLIAvailabilityStatus(kind: .unknown, version: nil)

    var summaryText: String {
        switch kind {
        case .available:
            if let version, !version.isEmpty {
                return "已检测到 \(displayName)（\(version)）"
            }
            return "已检测到 \(displayName)"
        case .notInstalled:
            return "未检测到 \(displayName) 可执行文件"
        case .notAuthenticated:
            return "\(displayName) 尚未认证"
        case .failed(let message):
            return "检测失败：\(message)"
        case .unknown:
            return "尚未检测 \(displayName) 状态"
        }
    }
}

struct ACPCLIAvailabilityService {
    private let fileManager: FileManager
    private let environment: [String: String]
    private let loginShellPathResolver: ShellEnvironmentResolver.LoginShellPathResolver

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPathResolver: @escaping ShellEnvironmentResolver.LoginShellPathResolver = ShellEnvironmentResolver.resolveLoginShellPath
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.loginShellPathResolver = loginShellPathResolver
    }

    func quickStatus(executablePath: String, displayName: String) -> ACPCLIAvailabilityStatus {
        guard ShellEnvironmentResolver.resolveExecutableURL(
            command: executablePath,
            baseEnvironment: environment,
            fileManager: fileManager,
            loginShellPathResolver: loginShellPathResolver
        ) != nil else {
            return ACPCLIAvailabilityStatus(kind: .notInstalled, version: nil, displayName: displayName)
        }

        return ACPCLIAvailabilityStatus(kind: .available, version: nil, displayName: displayName)
    }

    func checkStatus(executablePath: String, displayName: String) async throws -> ACPCLIAvailabilityStatus {
        await Task.detached(priority: .utility) {
            quickStatus(executablePath: executablePath, displayName: displayName)
        }.value
    }
}