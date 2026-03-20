import Foundation

typealias GitHubCopilotCLIAvailabilityStatus = ACPCLIAvailabilityStatus

struct GitHubCopilotCLIAvailabilityService {
    private let availabilityService: ACPCLIAvailabilityService

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPathResolver: @escaping ShellEnvironmentResolver.LoginShellPathResolver = ShellEnvironmentResolver.resolveLoginShellPath
    ) {
        self.availabilityService = ACPCLIAvailabilityService(
            fileManager: fileManager,
            environment: environment,
            loginShellPathResolver: loginShellPathResolver
        )
    }

    func quickStatus(configuration: GitHubCopilotCLIConfiguration) -> GitHubCopilotCLIAvailabilityStatus {
        availabilityService.quickStatus(
            executablePath: configuration.executablePath,
            displayName: "GitHub Copilot CLI"
        )
    }

    func checkStatus(configuration: GitHubCopilotCLIConfiguration) async throws -> GitHubCopilotCLIAvailabilityStatus {
        try await availabilityService.checkStatus(
            executablePath: configuration.executablePath,
            displayName: "GitHub Copilot CLI"
        )
    }
}