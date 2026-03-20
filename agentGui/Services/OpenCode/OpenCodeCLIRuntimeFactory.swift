import Foundation

struct OpenCodeCLIRuntimeFactory {
    func makeLaunchConfiguration(
        executablePath: String,
        workingDirectory: String,
        environmentOverrides: [String: String] = [:]
    ) -> ACPExternalAgentLaunchConfiguration {
        ACPExternalAgentLaunchConfiguration(
            command: executablePath,
            arguments: ["acp"],
            environmentOverrides: environmentOverrides,
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory)
        )
    }
}