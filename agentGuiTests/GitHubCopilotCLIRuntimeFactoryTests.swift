import Foundation
import Testing
@testable import agentGui

struct GitHubCopilotCLIRuntimeFactoryTests {
    @Test func runtimeFactoryLaunchesACPModeWithStdIO() throws {
        let factory = GitHubCopilotCLIRuntimeFactory()

        let launch = factory.makeLaunchConfiguration(
            executablePath: "/usr/local/bin/copilot",
            workingDirectory: "/tmp/project"
        )

        #expect(launch.command == "/usr/local/bin/copilot")
        #expect(launch.arguments == ["--acp", "--stdio"])
        #expect(launch.currentDirectoryURL == URL(fileURLWithPath: "/tmp/project"))
    }
}