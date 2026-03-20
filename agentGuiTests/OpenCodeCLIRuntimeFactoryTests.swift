import Foundation
import Testing
@testable import agentGui

struct OpenCodeCLIRuntimeFactoryTests {
    @Test func runtimeFactoryLaunchesOpenCodeACPMode() throws {
        let factory = OpenCodeCLIRuntimeFactory()

        let launch = factory.makeLaunchConfiguration(
            executablePath: "/usr/local/bin/opencode",
            workingDirectory: "/tmp/project"
        )

        #expect(launch.command == "/usr/local/bin/opencode")
        #expect(launch.arguments == ["acp"])
        #expect(launch.currentDirectoryURL == URL(fileURLWithPath: "/tmp/project"))
        #expect(launch.environmentOverrides.isEmpty)
    }
}