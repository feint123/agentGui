import Foundation
import Testing
@testable import agentGui

struct GitHubCopilotCLIAvailabilityServiceTests {
    @Test func unavailableWhenExecutableMissing() async throws {
        let service = GitHubCopilotCLIAvailabilityService(fileManager: .default)

        let status = try await service.checkStatus(
            configuration: GitHubCopilotCLIConfiguration(
                executablePath: "/missing/copilot",
                defaultModel: "",
                customAgentName: "",
                defaultApprovalMode: "default",
                useACPStdIO: true
            )
        )

        #expect(status.kind == .notInstalled)
    }

    @Test func availableWhenExecutableIsOnlyResolvableViaLoginShellPath() async throws {
        let temporaryDirectory = makeTemporaryDirectory()
        let executableURL = temporaryDirectory.appendingPathComponent("copilot")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/zsh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let service = GitHubCopilotCLIAvailabilityService(
            fileManager: .default,
            environment: ["PATH": "/usr/bin"],
            loginShellPathResolver: { _ in temporaryDirectory.path }
        )

        let status = try await service.checkStatus(
            configuration: GitHubCopilotCLIConfiguration(
                executablePath: "copilot",
                defaultModel: "",
                customAgentName: "",
                defaultApprovalMode: "default",
                useACPStdIO: true
            )
        )

        #expect(status.kind == .available)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}