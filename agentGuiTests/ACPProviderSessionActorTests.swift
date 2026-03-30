import Foundation
import Testing
@testable import agentGui

struct ACPProviderSessionActorTests {
    @Test
    func registryReturnsSameActorForSameSessionKey() async {
        let registry = ACPProviderSessionActorRegistry()
        let key = SessionRuntimeKey(
            providerReference: .externalACP(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            localSessionID: "session-a"
        )

        let first = await registry.actor(for: key) {
            ACPProviderSessionActor(localSessionID: "session-a", hooks: .init())
        }
        let second = await registry.actor(for: key) {
            ACPProviderSessionActor(localSessionID: "session-a", hooks: .init())
        }

        #expect(first === second)
    }

    @Test
    func sendRunsSuccessPathInFixedOrder() async throws {
        let probe = ACPProviderSessionActorTestProbe()
        let actor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: probe, promptBehavior: .succeed(.endTurn))
        )

        try await actor.sendPreparedTurn(.fixture(requestText: "hello"))

        #expect(await probe.steps == [
            .beginPrompt(requestText: "hello"),
            .promptStarted(remoteSessionID: "remote-a"),
            .promptFinished(stopReason: .endTurn),
            .flushProjectedUpdates,
            .finalizeAssistantMessage(requestText: "hello"),
            .finishLiveTurn
        ])
    }

    @Test
    func sendRecordsCancelCleanupWithoutFinalize() async {
        let probe = ACPProviderSessionActorTestProbe()
        let actor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: probe, promptBehavior: .cancel)
        )

        await #expect(throws: CancellationError.self) {
            try await actor.sendPreparedTurn(.fixture(requestText: "cancel me"))
        }

        let steps = await probe.steps
        #expect(steps.contains(.cancelCleanup))
        #expect(steps.contains(.finalizeAssistantMessage(requestText: "cancel me")) == false)
    }

    @Test
    func sendRecordsFailCleanupAndRethrows() async {
        struct ProbeFailure: Error, Equatable {}

        let probe = ACPProviderSessionActorTestProbe()
        let actor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: probe, promptBehavior: .fail(ProbeFailure()))
        )

        await #expect(throws: ProbeFailure.self) {
            try await actor.sendPreparedTurn(.fixture(requestText: "fail me"))
        }

        let steps = await probe.steps
        #expect(steps.contains(.failCleanup))
        #expect(steps.contains(.finalizeAssistantMessage(requestText: "fail me")) == false)
    }

    @Test
    func sendSerializesConcurrentTurnsForSameSession() async throws {
        let probe = ACPProviderSessionActorTestProbe()
        let gate = AsyncGate()
        let actor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: probe, promptGate: gate)
        )

        let first = Task {
            try await actor.sendPreparedTurn(.fixture(requestText: "first"))
        }
        try await probe.waitUntilContains(.beginPrompt(requestText: "first"))

        let second = Task {
            try await actor.sendPreparedTurn(.fixture(requestText: "second"))
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.contains(.beginPrompt(requestText: "second")) == false)

        await gate.release()
        _ = try await first.value
        _ = try await second.value

        let firstFinalize = try #require(await probe.index(of: .finalizeAssistantMessage(requestText: "first")))
        let secondBegin = try #require(await probe.index(of: .beginPrompt(requestText: "second")))
        #expect(firstFinalize < secondBegin)
    }

    @Test
    func sendAllowsDifferentSessionsToProceedIndependently() async throws {
        let sharedGate = AsyncGate()
        let firstProbe = ACPProviderSessionActorTestProbe()
        let secondProbe = ACPProviderSessionActorTestProbe()
        let firstActor = ACPProviderSessionActor(
            localSessionID: "session-a",
            hooks: .fixture(probe: firstProbe, promptGate: sharedGate)
        )
        let secondActor = ACPProviderSessionActor(
            localSessionID: "session-b",
            hooks: .fixture(probe: secondProbe, promptGate: sharedGate)
        )

        let first = Task {
            try await firstActor.sendPreparedTurn(.fixture(requestText: "first", localSessionID: "session-a"))
        }
        try await firstProbe.waitUntilContains(.beginPrompt(requestText: "first"))

        let second = Task {
            try await secondActor.sendPreparedTurn(.fixture(requestText: "second", localSessionID: "session-b", remoteSessionID: "remote-b"))
        }
        try await secondProbe.waitUntilContains(.beginPrompt(requestText: "second"))

        await sharedGate.release()
        _ = try await first.value
        _ = try await second.value
    }
}