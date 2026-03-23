import Foundation

actor ACPSessionRuntimeActor {
    enum Error: Swift.Error {
        case runtimeFactoryUnavailable
    }

    struct PreparedRuntimeSession {
        let runtimeClient: any ACPExternalProviderRuntimeTransportClient
        let handshake: ACPExternalAgentSessionHandshake
    }

    typealias RuntimeFactory = @Sendable (String, RuntimeActivationID) async throws -> any ACPExternalProviderRuntimeTransportClient
    typealias BindingLoader = @Sendable (SessionRuntimeKey) async throws -> String?
    typealias BindingPersister = @Sendable (SessionRuntimeKey, ACPExternalAgentSessionHandshake) async throws -> Void

    let key: SessionRuntimeKey

    private let runtimeFactory: RuntimeFactory
    private let bindingLoader: BindingLoader
    private let bindingPersister: BindingPersister

    private var runtimeClient: (any ACPExternalProviderRuntimeTransportClient)?
    private var runtimeWorkingDirectory: String?
    private(set) var activationID: RuntimeActivationID
    private(set) var stateMachine = ACPSessionRuntimeStateMachine()
    private(set) var closeCount = 0
    private(set) var runtimeRebuildCount = 0
    private(set) var lastHandshake: ACPExternalAgentSessionHandshake?

    init(
        key: SessionRuntimeKey,
        activationID: RuntimeActivationID = RuntimeActivationID(),
        runtimeFactory: @escaping @Sendable (String, RuntimeActivationID) async throws -> any ACPExternalProviderRuntimeTransportClient = { _, _ in
            throw Error.runtimeFactoryUnavailable
        },
        bindingLoader: @escaping @Sendable (SessionRuntimeKey) async throws -> String? = { _ in nil },
        bindingPersister: @escaping @Sendable (SessionRuntimeKey, ACPExternalAgentSessionHandshake) async throws -> Void = { _, _ in }
    ) {
        self.key = key
        self.activationID = activationID
        self.runtimeFactory = runtimeFactory
        self.bindingLoader = bindingLoader
        self.bindingPersister = bindingPersister
    }

    func rebuildActivation() -> RuntimeActivationID {
        let nextActivationID = RuntimeActivationID()
        activationID = nextActivationID
        stateMachine = ACPSessionRuntimeStateMachine()
        runtimeClient = nil
        runtimeWorkingDirectory = nil
        lastHandshake = nil
        runtimeRebuildCount += 1
        return nextActivationID
    }

    func transition(_ event: ACPSessionRuntimeStateMachine.Event) throws {
        try transitionStateMachine(event)
    }

    func prepareSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        try await prepareRuntimeSession(workingDirectory: workingDirectory).handshake
    }

    func prepareRuntimeSession(workingDirectory: String) async throws -> PreparedRuntimeSession {
        do {
            return try await prepareRuntimeSessionOnce(workingDirectory: workingDirectory)
        } catch ACPExternalAgentRuntimeError.initializeTimedOut {
            _ = await replaceRuntime()
            return try await prepareRuntimeSessionOnce(workingDirectory: workingDirectory)
        }
    }

    private func prepareRuntimeSessionOnce(workingDirectory: String) async throws -> PreparedRuntimeSession {
        let client = try await runtimeClientIfNeeded(workingDirectory: workingDirectory)
        let capabilities = try await client.initializeIfNeeded()
        let persistedRemoteSessionID = try await bindingLoader(key)

        if stateMachine.phase == .ready,
           let lastHandshake,
           runtimeWorkingDirectory == workingDirectory {
            if persistedRemoteSessionID == nil || persistedRemoteSessionID == lastHandshake.remoteSessionID {
                return PreparedRuntimeSession(runtimeClient: client, handshake: lastHandshake)
            }

            _ = await replaceRuntime()
            return try await prepareRuntimeSessionOnce(workingDirectory: workingDirectory)
        }

        if let remoteSessionID = persistedRemoteSessionID, capabilities.loadSession {
            try transitionStateMachine(.beginRestore)
            if let restored = try await client.loadSessionIfPossible(
                workingDirectory: workingDirectory,
                remoteSessionID: remoteSessionID
            ) {
                try await bindingPersister(key, restored)
                lastHandshake = restored
                try transitionStateMachine(.finishRestore)
                return PreparedRuntimeSession(runtimeClient: client, handshake: restored)
            }

            _ = await replaceRuntime()
        }

        let freshClient = try await runtimeClientIfNeeded(workingDirectory: workingDirectory)
        _ = try await freshClient.initializeIfNeeded()
        let handshake = try await freshClient.createSession(workingDirectory: workingDirectory)
        try await bindingPersister(key, handshake)
        lastHandshake = handshake
        try transitionStateMachine(.finishRestore)
        return PreparedRuntimeSession(runtimeClient: freshClient, handshake: handshake)
    }

    func close() async {
        if let runtimeClient {
            await runtimeClient.close()
            self.runtimeClient = nil
        }
        runtimeWorkingDirectory = nil
        closeCount += 1
    }

    func cancel(sessionID: String) async throws {
        guard let runtimeClient else { return }
        try await runtimeClient.cancel(sessionID: sessionID)
    }

    private func runtimeClientIfNeeded(
        workingDirectory: String
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        if let runtimeClient,
           runtimeWorkingDirectory == workingDirectory {
            return runtimeClient
        }

        if runtimeClient != nil,
           runtimeWorkingDirectory != workingDirectory {
            _ = await replaceRuntime()
        }

        try transitionStateMachine(.startRuntime)
        let created = try await runtimeFactory(workingDirectory, activationID)
        runtimeClient = created
        runtimeWorkingDirectory = workingDirectory
        try transitionStateMachine(.runtimeStarted)
        return created
    }

    private func transitionStateMachine(_ event: ACPSessionRuntimeStateMachine.Event) throws {
        var nextStateMachine = stateMachine
        try nextStateMachine.transition(event)
        stateMachine = nextStateMachine
    }

    private func replaceRuntime() async -> RuntimeActivationID {
        if let runtimeClient {
            await runtimeClient.close()
            self.runtimeClient = nil
        }
        runtimeWorkingDirectory = nil
        return rebuildActivation()
    }
}