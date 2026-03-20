import Foundation

struct GitHubCopilotCLILaunchConfiguration: Equatable, Sendable {
    let command: String
    let arguments: [String]
    let currentDirectoryURL: URL
}

struct GitHubCopilotCLIRuntimeFactory {
    func makeLaunchConfiguration(
        executablePath: String,
        workingDirectory: String
    ) -> GitHubCopilotCLILaunchConfiguration {
        GitHubCopilotCLILaunchConfiguration(
            command: executablePath,
            arguments: ["--acp", "--stdio"],
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
    }
}