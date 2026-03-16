import Foundation
import Testing
@testable import agentGui

struct TerminalTaskModelsTests {

    @Test func executionModeAcceptsOnlyPtyModes() async throws {
        #expect(TerminalExecutionMode(rawValue: "attached") != nil)
        #expect(TerminalExecutionMode(rawValue: "detached") != nil)
        #expect(TerminalExecutionMode(rawValue: "foreground") == nil)
    }

    @Test func statusKnowsNewPtyTerminalLifecycle() async throws {
        #expect(TerminalTaskStatus(rawValue: "running") != nil)
        #expect(TerminalTaskStatus(rawValue: "waitingForInput") != nil)
        #expect(TerminalTaskStatus(rawValue: "terminated") != nil)
        #expect(TerminalTaskStatus(rawValue: "runningForeground") == nil)
    }

    @Test func statusKnowsWhetherTaskIsTerminal() async throws {
        #expect(TerminalTaskStatus.completed.isTerminal)
        #expect(TerminalTaskStatus.failed.isTerminal)
        #expect(!TerminalTaskStatus.running.isTerminal)
        #expect(!TerminalTaskStatus.waitingForInput.isTerminal)
    }

    @Test func promptSnapshotMasksSensitiveKinds() async throws {
        let snapshot = TerminalPromptSnapshot(
            kind: .secret,
            promptText: "Password:",
            options: [],
            recommendedReply: nil
        )

        #expect(snapshot.shouldMaskReply)
    }

    @Test func promptSnapshotDoesNotMaskNormalChoices() async throws {
        let snapshot = TerminalPromptSnapshot(
            kind: .yesNo,
            promptText: "Proceed? (y/N)",
            options: ["y", "n"],
            recommendedReply: "n"
        )

        #expect(!snapshot.shouldMaskReply)
    }

    @Test func registryStoresAndUpdatesTaskSnapshots() async throws {
        let registry = BashTaskRegistry()
        let task = TerminalTaskSnapshot.fixture(id: "task-1", status: .launching)

        await registry.upsert(task)
        await registry.updateStatus(taskId: "task-1", status: .running)

        let loaded = await registry.snapshot(taskId: "task-1")

        #expect(loaded?.status == .running)
    }

    @MainActor
    @Test func claudeServiceProvidesSessionScopedTaskRegistries() async throws {
        let service = ClaudeService()
        let firstRegistry = service.getBashTaskRegistry(for: "session-a")
        let sameSessionRegistry = service.getBashTaskRegistry(for: "session-a")
        let secondRegistry = service.getBashTaskRegistry(for: "session-b")

        await firstRegistry.upsert(TerminalTaskSnapshot.fixture(id: "task-a", sessionId: "session-a"))

        #expect(await sameSessionRegistry.snapshot(taskId: "task-a")?.sessionId == "session-a")
        #expect(await secondRegistry.snapshot(taskId: "task-a") == nil)
    }
}