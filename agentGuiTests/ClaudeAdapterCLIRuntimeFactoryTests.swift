import Foundation
import Testing
@testable import agentGui

struct ClaudeAdapterCLIRuntimeFactoryTests {
    @Test func runtimeFactoryLaunchesClaudeAdapterBinaryDirectly() throws {
        let factory = ClaudeAdapterCLIRuntimeFactory()

        let launch = factory.makeLaunchConfiguration(
            executablePath: "/usr/local/bin/claude-agent-acp",
            workingDirectory: "/tmp/project"
        )

        #expect(launch.command == "/usr/local/bin/claude-agent-acp")
        #expect(launch.arguments.isEmpty)
        #expect(launch.currentDirectoryURL == URL(fileURLWithPath: "/tmp/project"))
        #expect(launch.environmentOverrides.isEmpty)
    }
}