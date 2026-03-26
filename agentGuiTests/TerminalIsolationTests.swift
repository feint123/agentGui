import Foundation
import Testing
@testable import agentGui

struct TerminalIsolationTests {
    @Test
    func terminalInfrastructureTypesAreDetachedTaskSafe() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let result = try await Task.detached {
            let transcriptStore = TerminalTranscriptStore(baseDirectory: baseDirectory)
            try transcriptStore.createTranscript(taskId: "task-1")
            try transcriptStore.append("line-1\nline-2\n", to: "task-1")

            let shellEvents = TerminalShellIntegrationParser().parse("\u{001B}]633;A\u{0007}\u{001B}]633;P;Cwd=/tmp/project\u{0007}")
            let vtEvents = TerminalVTParser().parse("hello\r\n\u{001B}[31mworld\u{001B}[0m")
            let encodedKey = TerminalKeyEncoder().encode(.enter)

            var screenModel = TerminalScreenModel()
            screenModel.apply(.print("hello"))
            let screenSnapshot = screenModel.snapshot()

            let taskSnapshot = TerminalTaskSnapshot(
                id: "task-1",
                sessionId: "session-1",
                command: "echo hello",
                executionMode: .detached,
                status: .running,
                latestOutputSnippet: try transcriptStore.readTail(taskId: "task-1", lineCount: 1),
                startedAt: Date()
            )
            let outcome = TerminalExecutionOutcome(
                taskId: "task-1",
                exitCode: 0,
                terminationSignal: nil,
                completionReason: .exitedZero,
                startedAt: taskSnapshot.startedAt,
                endedAt: Date(),
                transcriptPath: transcriptStore.transcriptURL(taskId: "task-1").path,
                finalOutputSnippet: "line-1\nline-2"
            )

            let controller = try PtyProcessController(
                command: "printf 'terminal detached test'",
                shell: "/bin/zsh",
                workingDirectory: nil,
                environment: ProcessInfo.processInfo.environment
            )

            return (
                shellEvents.count,
                vtEvents.count,
                encodedKey,
                screenSnapshot.plainTextLines,
                taskSnapshot.status,
                outcome.completionReason,
                controller.processIdentifier
            )
        }.value

        #expect(result.0 == 2)
        #expect(result.1 >= 3)
        #expect(result.2 == "\r")
        #expect(result.3.first == "hello")
        #expect(result.4 == .running)
        #expect(result.5 == .exitedZero)
        #expect(result.6 == 0)
    }
}