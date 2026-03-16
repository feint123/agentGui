import Foundation
import Testing
@testable import agentGui

struct TerminalTaskRuntimeTests {

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
}