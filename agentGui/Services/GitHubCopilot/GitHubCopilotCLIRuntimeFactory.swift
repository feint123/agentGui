import Foundation

typealias GitHubCopilotCLILaunchConfiguration = ACPExternalAgentLaunchConfiguration

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