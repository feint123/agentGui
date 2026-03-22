import Foundation

struct OpenCodeCLIRuntimeFactory {
    func makeLaunchConfiguration(
        executablePath: String,
        workingDirectory: String
    ) -> ACPExternalAgentLaunchConfiguration {
        ACPExternalAgentLaunchConfiguration(
            command: executablePath,
            arguments: ["acp"],
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
    }
}