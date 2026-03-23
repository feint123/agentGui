import Foundation

struct ClaudeAdapterCLIRuntimeFactory {
    func makeLaunchConfiguration(
        executablePath: String,
        workingDirectory: String
    ) -> ACPExternalAgentLaunchConfiguration {
        ACPExternalAgentLaunchConfiguration(
            command: executablePath,
            arguments: [],
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
    }
}