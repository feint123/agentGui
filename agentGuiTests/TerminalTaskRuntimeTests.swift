import Foundation
import Testing
@testable import agentGui

struct TerminalTaskRuntimeTests {

    @Test func runtimeMaintainsScreenSnapshotFromStreamingOutput() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        _ = try await runtime.startDetached(command: "printf 'hello'", taskId: "screen-task")

        let snapshot = try await runtime.screenSnapshot(taskId: "screen-task")

        #expect(snapshot.plainTextLines.joined().contains("hello"))

        _ = try await runtime.waitForDetachedTask(taskId: "screen-task")
    }

    @Test func cleanupRemovesScreenSession() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        _ = try await runtime.startDetached(command: "sleep 1", taskId: "cleanup-screen")
        _ = try await runtime.screenSnapshot(taskId: "cleanup-screen")

        try await runtime.cleanup(taskId: "cleanup-screen")

        await #expect(throws: TerminalRuntimeError.taskNotFound) {
            _ = try await runtime.screenSnapshot(taskId: "cleanup-screen")
        }
    }

    @Test func runtimeRoutesControlByTaskId() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()
        let task = try await runtime.startDetached(command: "sleep 5", taskId: "srv")

        let status = try await runtime.status(taskId: task.id)

        #expect(status.id == "srv")
        #expect(status.status == .running)
        await #expect(throws: TerminalRuntimeError.taskNotFound) {
            _ = try await runtime.status(taskId: "missing")
        }

        try await runtime.terminate(taskId: task.id, force: false)
        _ = try await runtime.waitForDetachedTask(taskId: task.id)
    }

    @Test func runtimeCompletesAttachedCommandWithOutcome() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        let outcome = try await runtime.startAttached(command: "echo attached", taskId: "attached-task")

        #expect(outcome.taskId == "attached-task")
        #expect(outcome.completionReason == .exitedZero)
        #expect(outcome.finalOutputSnippet.contains("attached"))
    }

    @Test func runtimeRejectsDuplicateTaskIdWithHelpfulError() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        _ = try await runtime.startAttached(command: "echo first", taskId: "list_files")

        await #expect(throws: TerminalRuntimeError.taskAlreadyExists) {
            _ = try await runtime.startAttached(command: "echo second", taskId: "list_files")
        }

        #expect(TerminalRuntimeError.taskAlreadyExists.errorDescription?.contains("cleanup") == true)
    }

    @Test func runtimeStartsCommandsInProvidedWorkingDirectory() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()
        let workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let outcome = try await runtime.startAttached(
            command: "pwd",
            taskId: "pwd-task",
            workingDirectory: workingDirectory.path
        )

        #expect(outcome.exitCode == 0)
        #expect(outcome.finalOutputSnippet.contains(workingDirectory.path))
    }

    @Test func runtimeUpdatesSnapshotFromShellIntegrationEvents() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        _ = try await runtime.startDetached(command: "sleep 1", taskId: "shell-events")
        try await runtime.ingestShellIntegrationOutput(
            taskId: "shell-events",
            output: "\u{001B}]633;P;Cwd=/tmp/demo\u{07}\u{001B}]633;E;npm create vue@latest vue3-demo\u{07}"
        )

        let snapshot = try await runtime.status(taskId: "shell-events")

        #expect(snapshot.currentWorkingDirectory == "/tmp/demo")
        #expect(snapshot.shellCommandLine == "npm create vue@latest vue3-demo")

        try await runtime.terminate(taskId: "shell-events", force: false)
        _ = try await runtime.waitForDetachedTask(taskId: "shell-events")
    }

    @Test func runtimeAppliesStructuredInteractionActionsInOrder() async throws {
        let runtime = await TerminalTaskRuntime.makeForTests()

        _ = try await runtime.startDetached(
            command: ###"""
python3 -c 'import sys; sys.stdout.write("menu\\n"); sys.stdout.flush(); data = sys.stdin.buffer.read(6); print("input-bytes:" + " ".join(str(b) for b in data))'
"""###,
            taskId: "interaction-actions"
        )

        try await runtime.applyInteractionActions(
            taskId: "interaction-actions",
            actions: [.key(.space), .key(.down), .key(.space), .key(.enter)]
        )

        let outcome = try await runtime.waitForDetachedTask(taskId: "interaction-actions")

        #expect(outcome.finalOutputSnippet.contains("input-bytes:32 27 91 66 32 10"))
    }
}