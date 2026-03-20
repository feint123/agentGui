import Foundation
import Testing
@testable import agentGui

struct ShellEnvironmentResolverTests {
    @Test func resolvedEnvironmentUsesLoginShellPathWhenAvailable() throws {
        let resolved = ShellEnvironmentResolver.resolvedEnvironment(
            baseEnvironment: ["PATH": "/usr/bin"],
            loginShellPathResolver: { _ in "/opt/homebrew/bin:/usr/bin" }
        )

        #expect(resolved["PATH"] == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func resolveExecutableURLFindsBinaryInLoginShellPath() throws {
        let temporaryDirectory = makeTemporaryDirectory()
        let executableURL = temporaryDirectory.appendingPathComponent("copilot")
        FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/zsh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let resolved = ShellEnvironmentResolver.resolveExecutableURL(
            command: "copilot",
            baseEnvironment: ["PATH": "/usr/bin"],
            loginShellPathResolver: { _ in temporaryDirectory.path }
        )

        #expect(resolved?.path == executableURL.path)
    }

    @Test func resolveLoginShellPathCachesResolvedValue() throws {
        ShellEnvironmentResolver.resetLoginShellPathCacheForTesting()
        var invocationCount = 0

        let first = ShellEnvironmentResolver.resolveLoginShellPath(
            baseEnvironment: ["PATH": "/usr/bin"],
            processRunner: { _ in
                invocationCount += 1
                return "/opt/homebrew/bin:/usr/bin"
            }
        )
        let second = ShellEnvironmentResolver.resolveLoginShellPath(
            baseEnvironment: ["PATH": "/usr/bin"],
            processRunner: { _ in
                invocationCount += 1
                return "/tmp/should-not-be-used"
            }
        )

        #expect(first == "/opt/homebrew/bin:/usr/bin")
        #expect(second == "/opt/homebrew/bin:/usr/bin")
        #expect(invocationCount == 1)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}