import Foundation
import Testing
@testable import agentGui

struct TerminalTaskModelsTests {

    @Test func terminalInteractionActionSupportsKeyAndTextInput() async throws {
        let enter = TerminalInteractionAction.key(.enter)
        let text = TerminalInteractionAction.text("vue3-demo")

        #expect(enter.isKeyboardAction)
        #expect(!text.isKeyboardAction)
    }

    @Test func terminalSurfaceSnapshotCapturesVisibleOptions() async throws {
        let snapshot = TerminalSurfaceSnapshot(
            plainTextFrame: "feature menu",
            rawANSISnippet: "\u{001B}[32mfeature menu\u{001B}[0m",
            visibleOptions: [
                .init(label: "JSX 支持", isSelected: false, isFocused: true),
                .init(label: "Router", isSelected: true, isFocused: false)
            ],
            focusedOptionIndex: 0,
            selectionMode: .multiSelect,
            isAlternateScreen: true
        )

        #expect(snapshot.visibleOptions.count == 2)
        #expect(snapshot.selectionMode == .multiSelect)
        #expect(snapshot.isAlternateScreen)
    }

    @Test func terminalInteractionPlanTracksApprovalRequirement() async throws {
        let plan = TerminalInteractionPlan(
            interactionType: "multi_select_menu",
            intentSummary: "select vue features",
            confidence: 0.83,
            nextActions: [.key(.space), .key(.enter)],
            requiresUserConfirmation: false,
            reasoningSummary: "Matches requested feature set"
        )

        #expect(plan.nextActions.count == 2)
        #expect(plan.requiresUserConfirmation == false)
    }

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