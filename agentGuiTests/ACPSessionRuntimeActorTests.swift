import Foundation
import Testing
@testable import agentGui

@MainActor
struct ACPSessionRuntimeActorTests {
    @Test func actorRestoresExistingRemoteSessionWhenLoadSucceeds() async throws {
        let key = SessionRuntimeKey(providerID: .openCodeCLI, localSessionID: "session-restore")
        let runtimeClient = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "0.1.0"
            ),
            restoredHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-restored",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "0.1.0"
                )
            ),
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-new",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "0.1.0"
                )
            )
        )
        let recorder = BindingRecorder(initialRemoteSessionID: "remote-restored")
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in runtimeClient },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        let handshake = try await actor.prepareSession(workingDirectory: "/tmp/restore")

        #expect(handshake.remoteSessionID == "remote-restored")
        #expect(runtimeClient.loadRequests.count == 1)
        #expect(runtimeClient.loadRequests.first?.0 == "/tmp/restore")
        #expect(runtimeClient.loadRequests.first?.1 == "remote-restored")
        #expect(runtimeClient.createRequests.isEmpty)
        #expect(await actor.stateMachine.phase == .ready)
    }

    @Test func actorFallsBackToNewSessionAfterLoadFailure() async throws {
        let key = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-fallback")
        let firstRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-ignored",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let secondRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-new",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let factory = RuntimeFactoryQueue(runtimes: [firstRuntime, secondRuntime])
        let recorder = BindingRecorder(initialRemoteSessionID: "remote-old")
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in try await factory.next() },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        let handshake = try await actor.prepareSession(workingDirectory: "/tmp/fallback")

        #expect(handshake.remoteSessionID == "remote-new")
        #expect(firstRuntime.loadRequests.count == 1)
        #expect(firstRuntime.loadRequests.first?.0 == "/tmp/fallback")
        #expect(firstRuntime.loadRequests.first?.1 == "remote-old")
        #expect(firstRuntime.closeCallCount == 1)
        #expect(secondRuntime.createRequests == ["/tmp/fallback"])
        #expect(await actor.runtimeRebuildCount == 1)
        #expect(await recorder.persistedRemoteSessionID == "remote-new")
    }

    @Test func actorRebuildsRuntimeAfterInitializeTimeout() async throws {
        let key = SessionRuntimeKey(providerID: .openCodeCLI, localSessionID: "session-timeout")
        let stalledRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "0.1.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-stalled",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "0.1.0"
                )
            ),
            initializeError: ACPExternalAgentRuntimeError.initializeTimedOut
        )
        let recoveredRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "0.1.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-recovered",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "0.1.0"
                )
            )
        )
        let factory = RuntimeFactoryQueue(runtimes: [stalledRuntime, recoveredRuntime])
        let recorder = BindingRecorder(initialRemoteSessionID: nil)
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in try await factory.next() },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        let prepared = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/timeout")

        #expect(prepared.handshake.remoteSessionID == "remote-recovered")
        #expect(stalledRuntime.closeCallCount == 1)
        #expect(recoveredRuntime.createRequests == ["/tmp/timeout"])
        #expect(await actor.runtimeRebuildCount == 1)
    }

    @Test func actorRebuildsRuntimeWhenWorkingDirectoryChanges() async throws {
        let key = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-working-directory")
        let firstRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: false,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-one",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: false,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let secondRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: false,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: nil,
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-two",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: false,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let factory = RuntimeFactoryQueue(runtimes: [firstRuntime, secondRuntime])
        let recorder = BindingRecorder(initialRemoteSessionID: nil)
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in try await factory.next() },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        _ = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/one")
        let prepared = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/two")

        #expect(prepared.handshake.remoteSessionID == "remote-two")
        #expect(firstRuntime.closeCallCount == 1)
        #expect(secondRuntime.createRequests == ["/tmp/two"])
        #expect(await actor.runtimeRebuildCount == 1)
    }

    @Test func actorReusesReadyActivationWithoutReenteringRestore() async throws {
        let key = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-ready-reuse")
        let runtimeClient = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-existing",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            ),
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-new",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let recorder = BindingRecorder(initialRemoteSessionID: "remote-existing")
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in runtimeClient },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        let first = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/reuse")
        let second = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/reuse")

        #expect(first.handshake.remoteSessionID == "remote-existing")
        #expect(second.handshake.remoteSessionID == "remote-existing")
        #expect(runtimeClient.loadRequests.count == 1)
        #expect(runtimeClient.createRequests.isEmpty)
        #expect(await actor.stateMachine.phase == .ready)
    }

    @Test func actorRebuildsReadyActivationWhenBindingChanges() async throws {
        let key = SessionRuntimeKey(providerID: .githubCopilotCLI, localSessionID: "session-ready-rebind")
        let firstRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-existing",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            ),
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-unused",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let reboundRuntime = RuntimeTransportStub(
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            restoredHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-rebound",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            ),
            createdHandshake: ACPExternalAgentSessionHandshake(
                remoteSessionID: "remote-new",
                capabilities: ACPExternalAgentCapabilitySnapshot(
                    loadSession: true,
                    supportsSessionModelOverride: true,
                    agentVersion: "1.0.0"
                )
            )
        )
        let factory = RuntimeFactoryQueue(runtimes: [firstRuntime, reboundRuntime])
        let recorder = BindingRecorder(initialRemoteSessionID: "remote-existing")
        let actor = ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { _, _ in try await factory.next() },
            bindingLoader: { _ in await recorder.load() },
            bindingPersister: { _, handshake in await recorder.persist(handshake: handshake) }
        )

        let first = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/rebind")
        await recorder.setRemoteSessionID("remote-rebound")
        let rebound = try await actor.prepareRuntimeSession(workingDirectory: "/tmp/rebind")

        #expect(first.handshake.remoteSessionID == "remote-existing")
        #expect(rebound.handshake.remoteSessionID == "remote-rebound")
        #expect(firstRuntime.closeCallCount == 1)
        #expect(reboundRuntime.loadRequests.count == 1)
        #expect(reboundRuntime.loadRequests.first?.1 == "remote-rebound")
        #expect(await actor.runtimeRebuildCount == 1)
        #expect(await actor.stateMachine.phase == .ready)
    }
}

private actor BindingRecorder {
    private let initialRemoteSessionID: String?
    private(set) var persistedRemoteSessionID: String?

    init(initialRemoteSessionID: String?) {
        self.initialRemoteSessionID = initialRemoteSessionID
    }

    func load() -> String? {
        persistedRemoteSessionID ?? initialRemoteSessionID
    }

    func persist(handshake: ACPExternalAgentSessionHandshake) {
        persistedRemoteSessionID = handshake.remoteSessionID
    }

    func setRemoteSessionID(_ remoteSessionID: String?) {
        persistedRemoteSessionID = remoteSessionID
    }
}

private actor RuntimeFactoryQueue {
    private var runtimes: [RuntimeTransportStub]

    init(runtimes: [RuntimeTransportStub]) {
        self.runtimes = runtimes
    }

    func next() throws -> RuntimeTransportStub {
        guard runtimes.isEmpty == false else {
            throw RuntimeTransportStub.FactoryError.missingFactoryRuntime
        }
        return runtimes.removeFirst()
    }
}

@MainActor
private final class RuntimeTransportStub: ACPExternalProviderRuntimeTransportClient {
    enum FactoryError: Swift.Error {
        case missingFactoryRuntime
    }

    let capabilities: ACPExternalAgentCapabilitySnapshot
    let restoredHandshake: ACPExternalAgentSessionHandshake?
    let createdHandshake: ACPExternalAgentSessionHandshake
    let initializeError: (any Error)?

    private(set) var initializeCallCount = 0
    private(set) var loadRequests: [(String, String)] = []
    private(set) var createRequests: [String] = []
    private(set) var closeCallCount = 0

    init(
        capabilities: ACPExternalAgentCapabilitySnapshot,
        restoredHandshake: ACPExternalAgentSessionHandshake?,
        createdHandshake: ACPExternalAgentSessionHandshake,
        initializeError: (any Error)? = nil
    ) {
        self.capabilities = capabilities
        self.restoredHandshake = restoredHandshake
        self.createdHandshake = createdHandshake
        self.initializeError = initializeError
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        initializeCallCount += 1
        if let initializeError {
            throw initializeError
        }
        return capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        loadRequests.append((workingDirectory, remoteSessionID))
        return restoredHandshake
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        createRequests.append(workingDirectory)
        return createdHandshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        _ = modelID
        _ = sessionID
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        _ = text
        _ = sessionID
        return .endTurn
    }

    func cancel(sessionID: String) async throws {
        _ = sessionID
    }

    func close() async {
        closeCallCount += 1
    }
}