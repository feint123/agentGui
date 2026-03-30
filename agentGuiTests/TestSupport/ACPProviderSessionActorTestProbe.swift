import Foundation
import Testing
@testable import agentGui

actor ACPProviderSessionActorTestProbe: ACPProviderSessionActorStepSink {
    private var recordedSteps: [ACPProviderSessionActorStep] = []

    var steps: [ACPProviderSessionActorStep] {
        recordedSteps
    }

    func record(_ step: ACPProviderSessionActorStep) {
        recordedSteps.append(step)
    }

    func contains(_ step: ACPProviderSessionActorStep) -> Bool {
        recordedSteps.contains(step)
    }


    func index(of step: ACPProviderSessionActorStep) -> Int? {
        recordedSteps.firstIndex(of: step)
    }

    func waitUntilContains(
        _ step: ACPProviderSessionActorStep,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while clock.now < deadline {
            if recordedSteps.contains(step) {
                return
            }
            await Task.yield()
        }

        Issue.record("Timed out waiting for step: \(step)")
        throw ACPProviderSessionActorTestProbeError.timedOut(step)
    }
}

enum ACPProviderSessionActorTestProbeError: Error {
    case timedOut(ACPProviderSessionActorStep)
}

enum ACPProviderSessionActorPromptBehavior {
    case succeed(ACPStopReason)
    case cancel
    case fail(any Error)
}

extension ACPProviderSessionActor.PreparedTurn {
    static func fixture(
        requestText: String,
        localSessionID: String = "session-a",
        remoteSessionID: String = "remote-a",
        promptText: String? = nil
    ) -> Self {
        Self(
            requestText: requestText,
            localSessionID: localSessionID,
            remoteSessionID: remoteSessionID,
            promptText: promptText ?? requestText,
            beginPromptAction: {},
            promptAction: { .endTurn },
            drainPendingUpdatesAction: {},
            flushProjectedUpdatesAction: {},
            finalizeAssistantMessageAction: { _ in },
            cancellationCleanupAction: {},
            failureCleanupAction: { _ in },
            finishLiveTurnAction: {}
        )
    }
}

extension ACPProviderSessionActor.Hooks {
    static func fixture(
        probe: ACPProviderSessionActorTestProbe,
        promptGate: AsyncGate? = nil,
        promptBehavior: ACPProviderSessionActorPromptBehavior = .succeed(.endTurn)
    ) -> Self {
        Self(
            beginPrompt: { turn in
                await probe.record(.beginPrompt(requestText: turn.requestText))
            },
            prompt: { turn in
                await probe.record(.promptStarted(remoteSessionID: turn.remoteSessionID))
                if let promptGate {
                    await promptGate.wait()
                }
                switch promptBehavior {
                case .succeed(let stopReason):
                    await probe.record(.promptFinished(stopReason: stopReason))
                    return stopReason
                case .cancel:
                    throw CancellationError()
                case .fail(let error):
                    throw error
                }
            },
            drainPendingUpdates: { _ in },
            flushProjectedUpdates: { _ in
                await probe.record(.flushProjectedUpdates)
            },
            finalizeAssistantMessage: { turn, _ in
                await probe.record(.finalizeAssistantMessage(requestText: turn.requestText))
            },
            handleCancellation: { _ in
                await probe.record(.cancelCleanup)
            },
            handleFailure: { _, _ in
                await probe.record(.failCleanup)
            },
            finishLiveTurn: { _ in
                await probe.record(.finishLiveTurn)
            }
        )
    }
}