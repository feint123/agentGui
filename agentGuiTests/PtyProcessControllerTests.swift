import Foundation
import Testing
@testable import agentGui

struct PtyProcessControllerTests {

    @Test func ptyControllerCapturesOutputAndExitCode() async throws {
        let controller = try PtyProcessController(
            command: "echo hello",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        let result = try await controller.runUntilExit()

        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello"))
        #expect(result.pid > 0)
    }

    @Test func ptyControllerAcceptsInput() async throws {
        let controller = try PtyProcessController(
            command: "read name; echo hi $name",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        try controller.start()
        try controller.sendInput("Ada\n")

        let result = try await controller.waitForExit()

        #expect(result.output.contains("hi Ada"))
    }

    @Test func ptyControllerInterruptsLongRunningCommand() async throws {
        let controller = try PtyProcessController(
            command: "sleep 30",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        try controller.start()
        try await Task.sleep(for: .milliseconds(150))
        try controller.interrupt()

        let result = try await controller.waitForExit()

        #expect(result.exitCode != 0)
    }

    @Test func ptyControllerResolvesPathFromZshrc() async throws {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binURL = homeURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let commandURL = binURL.appendingPathComponent("agentgui-test-cmd")
        try "#!/bin/zsh\necho from-zshrc\n".write(to: commandURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)

        let zshrcURL = homeURL.appendingPathComponent(".zshrc")
        try "export PATH=\"$HOME/bin:$PATH\"\n".write(to: zshrcURL, atomically: true, encoding: .utf8)

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

        let controller = try PtyProcessController(
            command: "agentgui-test-cmd",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: environment
        )

        let result = try await controller.runUntilExit()

        #expect(result.exitCode == 0)
        #expect(result.output.contains("from-zshrc"))
    }

    @Test func ptyControllerRecognizesCarriageReturnAsEnterKey() async throws {
        let controller = try PtyProcessController(
            command: "stty raw -echo; dd bs=1 count=1 2>/dev/null | od -An -t u1",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        try controller.start()
        try await Task.sleep(for: .milliseconds(80))
        try controller.sendInput(TerminalKeyEncoder().encode(.enter))

        let result = try await controller.waitForExit()
        let codeLine = result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last

        #expect(result.exitCode == 0)
        #expect(codeLine == "13")
    }

    @Test func ptyControllerPreservesRawCarriageReturnsForScreenConsumers() async throws {
        let controller = try PtyProcessController(
            command: #"printf 'A\rB'; sleep 0.2"#,
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        try controller.start()
        try await Task.sleep(for: .milliseconds(80))

        let rawOutput = controller.currentRawOutput()
        let normalizedOutput = controller.currentOutput()
        let result = try await controller.waitForExit()

        #expect(rawOutput.contains("\r"))
        #expect(result.rawOutput.contains("\r"))
        #expect(normalizedOutput.contains("\n"))
        #expect(result.output.contains("\n"))
    }

    @Test func ptyControllerReportsNonZeroTerminalSize() async throws {
        let controller = try PtyProcessController(
            command: "stty size",
            shell: "/bin/zsh",
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment
        )

        let result = try await controller.runUntilExit()
        let sizeLine = result.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { $0.first?.isNumber == true })

        #expect(result.exitCode == 0)
        #expect(sizeLine == "24 80")
    }
}