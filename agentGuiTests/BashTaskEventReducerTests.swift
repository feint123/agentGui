import Foundation
import Testing
@testable import agentGui

struct BashTaskEventReducerTests {

    @Test func emitsWaitingForPromptWhenOutputGoesIdleAndPromptDetected() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-1",
            sessionId: "session-1",
            command: "npx create-next-app demo",
            executionMode: .interactive,
            status: .runningForeground,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let prompt = try #require(BashPromptAnalyzer().analyze(output: "Install dependencies? (Y/n)"))
        let observation = TerminalTaskObservation(
            appendedOutput: "Install dependencies? (Y/n)",
            processIsAlive: true,
            idleDuration: 1.2,
            promptDecision: prompt,
            didBackgroundLaunch: false,
            didTimeout: false,
            exitCode: nil
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .waitingForPrompt)
        #expect(update.snapshot.prompt?.kind == .yesNo)
        #expect(update.events.contains { $0.kind == .promptDetected })
        #expect(update.events.contains { $0.kind == .stateChanged })
    }

    @Test func marksTaskAsBackgroundWhenLaunchTransitions() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-2",
            sessionId: "session-1",
            command: "npm run dev",
            executionMode: .background,
            status: .launching,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let observation = TerminalTaskObservation(
            appendedOutput: "[Background] PID: 123 | Log: /tmp/agentgui.log",
            processIsAlive: true,
            idleDuration: 0.1,
            promptDecision: nil,
            didBackgroundLaunch: true,
            didTimeout: false,
            exitCode: nil
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .runningBackground)
        #expect(update.events.contains { $0.kind == .backgroundRegistered })
    }

    @Test func completesTaskWhenProcessExitsSuccessfully() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-3",
            sessionId: "session-1",
            command: "xcodebuild test",
            executionMode: .foreground,
            status: .runningForeground,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let observation = TerminalTaskObservation(
            appendedOutput: "** TEST SUCCEEDED **",
            processIsAlive: false,
            idleDuration: 0.2,
            promptDecision: nil,
            didBackgroundLaunch: false,
            didTimeout: false,
            exitCode: 0
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .completed)
        #expect(update.events.contains { $0.kind == .processExit })
    }

    @Test func failsTaskWhenProcessExitsWithError() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-4",
            sessionId: "session-1",
            command: "swift test",
            executionMode: .foreground,
            status: .runningForeground,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let observation = TerminalTaskObservation(
            appendedOutput: "error: build failed",
            processIsAlive: false,
            idleDuration: 0.2,
            promptDecision: nil,
            didBackgroundLaunch: false,
            didTimeout: false,
            exitCode: 1
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .failed)
        #expect(update.events.contains { $0.kind == .processExit })
    }

    @Test func marksTaskTimedOutWhenObservationSignalsTimeout() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-5",
            sessionId: "session-1",
            command: "custom-tool",
            executionMode: .foreground,
            status: .runningForeground,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let observation = TerminalTaskObservation(
            appendedOutput: "",
            processIsAlive: true,
            idleDuration: 12,
            promptDecision: nil,
            didBackgroundLaunch: false,
            didTimeout: true,
            exitCode: nil
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .timedOut)
        #expect(update.events.contains { $0.kind == .stateChanged })
    }

    @Test func escalatesUnsafePromptToNeedsUserDecision() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot(
            id: "task-6",
            sessionId: "session-1",
            command: "sudo rm -i file.txt",
            executionMode: .interactive,
            status: .runningForeground,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let prompt = try #require(BashPromptAnalyzer().analyze(output: "Password:"))
        let observation = TerminalTaskObservation(
            appendedOutput: "Password:",
            processIsAlive: true,
            idleDuration: 1.0,
            promptDecision: prompt,
            didBackgroundLaunch: false,
            didTimeout: false,
            exitCode: nil
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .needsUserDecision)
        #expect(update.events.contains { $0.kind == .userDecisionRequested })
    }
}