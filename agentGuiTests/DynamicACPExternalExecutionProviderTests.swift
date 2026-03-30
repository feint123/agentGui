import Foundation
import Testing
@testable import agentGui

@MainActor
struct DynamicACPExternalExecutionProviderTests {
    @Test
    func sendRoutesBeginFlushFinalizeThroughSessionActor() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let probe = ACPProviderSessionActorTestProbe()
        let provider = makeProvider(probe: probe)

        try await provider.send(
            ConversationExecutionRequest(
                text: "hello session actor",
                session: harness.firstSession,
                modelID: "dynamic-model",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: harness.context
            )
        )

        let steps = await probe.steps
        #expect(steps.contains(.beginPrompt(requestText: "hello session actor")))
        #expect(steps.contains(.promptStarted(remoteSessionID: "remote-send")))
        #expect(steps.contains(.promptFinished(stopReason: .endTurn)))
        #expect(steps.contains(.flushProjectedUpdates))
        #expect(steps.contains(.finalizeAssistantMessage(requestText: "hello session actor")))
        #expect(steps.contains(.finishLiveTurn))

        let assistantMessage = try #require(harness.firstSession.messages.first(where: { $0.direction == .agent }))
        #expect(assistantMessage.status == .completed)
        #expect(assistantMessage.textContent == "(无响应)")
    }

    @Test
    func cancellationPathFlushesThenMarksCancelledFromActor() async throws {
        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let probe = ACPProviderSessionActorTestProbe()
        let provider = makeProvider(probe: probe, promptOutcome: .cancel)

        await #expect(throws: CancellationError.self) {
            try await provider.send(
                ConversationExecutionRequest(
                    text: "cancel session actor",
                    session: harness.firstSession,
                    modelID: "dynamic-model",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: [],
                    modelContext: harness.context
                )
            )
        }

        let flushIndex = try #require(await probe.index(of: .flushProjectedUpdates))
        let cancelIndex = try #require(await probe.index(of: .cancelCleanup))
        #expect(flushIndex < cancelIndex)

        let assistantMessage = try #require(harness.firstSession.messages.first(where: { $0.direction == .agent }))
        #expect(assistantMessage.status == .cancelled)
    }

    @Test
    func failurePathFlushesThenMarksFailedFromActor() async throws {
        struct PromptFailure: Error {}

        let harness = try MultiSessionExecutionFixtureFactory.makeProviderActivationHarness()
        let probe = ACPProviderSessionActorTestProbe()
        let provider = makeProvider(probe: probe, promptOutcome: .fail(PromptFailure()))

        await #expect(throws: PromptFailure.self) {
            try await provider.send(
                ConversationExecutionRequest(
                    text: "fail session actor",
                    session: harness.firstSession,
                    modelID: "dynamic-model",
                    selectedFilePath: nil,
                    selectedText: nil,
                    directives: [],
                    modelContext: harness.context
                )
            )
        }

        let flushIndex = try #require(await probe.index(of: .flushProjectedUpdates))
        let failIndex = try #require(await probe.index(of: .failCleanup))
        #expect(flushIndex < failIndex)

        let assistantMessage = try #require(harness.firstSession.messages.first(where: { $0.direction == .agent }))
        #expect(assistantMessage.status == .failed)
    }

    private func makeProvider(
        probe: ACPProviderSessionActorTestProbe,
        promptOutcome: DynamicACPExternalExecutionProviderTestRuntimeClient.PromptOutcome = .success(.endTurn)
    ) -> DynamicACPExternalExecutionProvider {
        let profile = ACPProviderProfile(
            displayName: "Dynamic Test Provider",
            executablePath: "/usr/bin/env",
            arguments: ["acp"],
            isEnabled: true,
            sortOrder: 0
        )

        return DynamicACPExternalExecutionProvider(
            profile: profile,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            sessionActorProbe: probe,
            runtimeClientFactory: { _, _, _, _, _ in
                DynamicACPExternalExecutionProviderTestRuntimeClient(promptOutcome: promptOutcome)
            }
        )
    }
}

private final class DynamicACPExternalExecutionProviderTestRuntimeClient: ACPExternalProviderRuntimeTransportClient {
    enum PromptOutcome {
        case success(ACPStopReason)
        case cancel
        case fail(any Error)
    }

    private let promptOutcome: PromptOutcome

    init(promptOutcome: PromptOutcome = .success(.endTurn)) {
        self.promptOutcome = promptOutcome
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        ACPExternalAgentCapabilitySnapshot(loadSession: true, supportsSessionModelOverride: true, agentVersion: "test")
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        ACPExternalAgentSessionHandshake(
            remoteSessionID: "remote-send",
            capabilities: try await initializeIfNeeded(),
            configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot(configOptions: [], modes: nil)
        )
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {}

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        []
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        switch promptOutcome {
        case .success(let stopReason):
            return stopReason
        case .cancel:
            throw CancellationError()
        case .fail(let error):
            throw error
        }
    }

    func cancel(sessionID: String) async throws {}

    func close() async {}
}