import Foundation

nonisolated enum ACPExternalAgentRuntimeError: LocalizedError, Equatable {
    case sessionAlreadyAttached(current: String, requested: String)
    case initializeTimedOut
    case runtimeNotRunning

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyAttached(let current, let requested):
            return "当前外部 ACP 运行时已绑定会话 \(current)，不能在同一运行时内切换到 \(requested)。"
        case .initializeTimedOut:
            return "外部 ACP 运行时在初始化阶段超时，未能返回 initialize 响应。"
        case .runtimeNotRunning:
            return "外部 ACP 运行时已经退出，当前缓存的会话运行时不可复用。"
        }
    }
}

private enum ACPExternalSessionRestoreError: Error {
    case timedOut
}

nonisolated struct ACPExternalAgentLaunchConfiguration: Equatable, Sendable {
    let command: String
    let arguments: [String]
    let environmentOverrides: [String: String]
    let currentDirectoryURL: URL

    init(
        command: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        currentDirectoryURL: URL
    ) {
        self.command = command
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.currentDirectoryURL = currentDirectoryURL
    }
}

nonisolated struct ACPExternalAgentCapabilitySnapshot: Codable, Equatable, Sendable {
    let loadSession: Bool
    let supportsSessionModelOverride: Bool
    let agentVersion: String?
}

nonisolated struct ACPExternalAgentSessionConfigurationSnapshot: Codable, Equatable, Sendable {
    let configOptions: [ACPSessionConfigOption]
    let modes: ACPSessionModeState?
}

nonisolated struct ACPExternalAgentSessionHandshake: Codable, Equatable, Sendable {
    let remoteSessionID: String
    let capabilities: ACPExternalAgentCapabilitySnapshot
    let configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot

    init(
        remoteSessionID: String,
        capabilities: ACPExternalAgentCapabilitySnapshot,
        configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot = ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: [],
            modes: nil
        )
    ) {
        self.remoteSessionID = remoteSessionID
        self.capabilities = capabilities
        self.configurationSnapshot = configurationSnapshot
    }
}

private actor ACPExternalAgentClientHandler: ACPClientHandler {
    private let localHandler: ACPLocalClientHandler
    private let eventSink: @Sendable (CopilotACPUpdate) async -> Void

    init(
        allowedRoots: [URL],
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: (@Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)?,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) {
        self.localHandler = ACPLocalClientHandler(
            authorizationPolicy: authorizationPolicy,
            allowedRoots: allowedRoots,
            terminalRuntimeProvider: { _ in terminalRuntime },
            permissionResolver: permissionResolver
        )
        self.eventSink = eventSink
    }

    func handleSessionUpdate(_ notification: ACPSessionNotification) async {
        await eventSink(.sessionNotification(notification))
    }

    func handleRequestPermission(_ request: ACPRequestPermissionRequest) async throws -> ACPRequestPermissionResponse? {
        await eventSink(.permission(request))
        return try await localHandler.handleRequestPermission(request)
    }

    func handleReadTextFile(_ request: ACPReadTextFileRequest) async throws -> ACPReadTextFileResponse? {
        try await localHandler.handleReadTextFile(request)
    }

    func handleWriteTextFile(_ request: ACPWriteTextFileRequest) async throws -> ACPWriteTextFileResponse? {
        try await localHandler.handleWriteTextFile(request)
    }

    func handleCreateTerminal(_ request: ACPCreateTerminalRequest) async throws -> ACPCreateTerminalResponse? {
        try await localHandler.handleCreateTerminal(request)
    }

    func handleTerminalOutput(_ request: ACPTerminalOutputRequest) async throws -> ACPTerminalOutputResponse? {
        try await localHandler.handleTerminalOutput(request)
    }

    func handleWaitForTerminalExit(_ request: ACPWaitForTerminalExitRequest) async throws -> ACPWaitForTerminalExitResponse? {
        try await localHandler.handleWaitForTerminalExit(request)
    }

    func handleKillTerminal(_ request: ACPKillTerminalRequest) async throws -> ACPKillTerminalResponse? {
        try await localHandler.handleKillTerminal(request)
    }

    func handleReleaseTerminal(_ request: ACPReleaseTerminalRequest) async throws -> ACPReleaseTerminalResponse? {
        try await localHandler.handleReleaseTerminal(request)
    }
}

nonisolated final class ACPExternalAgentRuntimeClient: @unchecked Sendable, ACPExternalProviderRuntimeClient, ACPExternalProviderRuntimeTransportClient {
    nonisolated private static let defaultLoadSessionTimeoutNanoseconds: UInt64 = 15_000_000_000
    nonisolated private static let defaultInitializeTimeoutNanoseconds: UInt64 = 15_000_000_000

    private let managedRuntime: ACPManagedClientRuntime
    private let initializeTimeoutNanoseconds: UInt64
    private let loadSessionTimeoutNanoseconds: UInt64
    private let debugID: String
    private let debugLogger: (@Sendable (String) -> Void)?
    private let stateLock = NSLock()
    private var capabilitySnapshot: ACPExternalAgentCapabilitySnapshot?
    private var attachedSessionHandshake: ACPExternalAgentSessionHandshake?

    init(
        launchConfiguration: ACPExternalAgentLaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        initializeTimeoutNanoseconds: UInt64 = ACPExternalAgentRuntimeClient.defaultInitializeTimeoutNanoseconds,
        loadSessionTimeoutNanoseconds: UInt64 = 5_000_000_000,
        debugLogger: (@Sendable (String) -> Void)? = nil,
        permissionResolver: (@Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)? = nil,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws {
        let debugID = Self.makeDebugID()
        self.debugID = debugID
        self.debugLogger = debugLogger
        self.initializeTimeoutNanoseconds = initializeTimeoutNanoseconds
        self.loadSessionTimeoutNanoseconds = loadSessionTimeoutNanoseconds
        let allowedRoot = launchConfiguration.currentDirectoryURL.standardizedFileURL
        let handler = ACPExternalAgentClientHandler(
            allowedRoots: [allowedRoot],
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
        self.managedRuntime = try ACPManagedClientRuntime.launch(
            command: launchConfiguration.command,
            arguments: launchConfiguration.arguments,
            environmentOverrides: launchConfiguration.environmentOverrides,
            currentDirectoryURL: launchConfiguration.currentDirectoryURL,
            clientHandler: handler,
            standardErrorHandler: { [debugLogger] (rawLine: String) in
                let message = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { return }
                if let debugLogger {
                    debugLogger("[runtime-client:\(debugID)] stderr \(message)")
                } else {
                    print("[ACP][runtime-client:\(debugID)] stderr \(message)")
                }
            },
            streamObserver: { [debugLogger] (event: ACPStreamEvent) in
                let summary = ACPExternalAgentRuntimeClient.summarize(event.message)
                if let debugLogger {
                    debugLogger("[runtime-client:\(debugID)] acp \(event.direction.rawValue) \(summary)")
                } else {
                    print("[ACP][runtime-client:\(debugID)] acp \(event.direction.rawValue) \(summary)")
                }
            },
            errorObserver: { [debugLogger] (error: Error) in
                let description = ACPExternalAgentRuntimeClient.describe(error)
                if let debugLogger {
                    debugLogger("[runtime-client:\(debugID)] connection-error \(description)")
                } else {
                    print("[ACP][runtime-client:\(debugID)] connection-error \(description)")
                }
            }
        )
        debugLog(
            "launch complete pid=\(managedRuntime.processIdentifier.map(String.init) ?? "nil") cwd=\(allowedRoot.path) command=\(launchConfiguration.command) args=\(launchConfiguration.arguments.joined(separator: " "))"
        )
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake {
        let currentHandshake = currentAttachedSessionHandshake()
        let hasCachedCapabilities = currentCapabilitySnapshot() != nil
        debugLog(
            "ensureSession start requestedRemote=\(remoteSessionID?.nonEmptyValue ?? "nil") workingDirectory=\(workingDirectory) attachedRemote=\(currentHandshake?.remoteSessionID ?? "nil") cachedCapabilities=\(hasCachedCapabilities) runtimeRunning=\(managedRuntime.isRunning)"
        )
        let capabilities = try await initializeIfNeeded()
        debugLog(
            "ensureSession capabilities loadSession=\(capabilities.loadSession) supportsSessionModelOverride=\(capabilities.supportsSessionModelOverride) agentVersion=\(capabilities.agentVersion ?? "nil")"
        )

        if let attachedSessionHandshake = currentAttachedSessionHandshake() {
            if let remoteSessionID = remoteSessionID?.nonEmptyValue {
                guard attachedSessionHandshake.remoteSessionID == remoteSessionID else {
                    debugLog(
                        "ensureSession attached mismatch current=\(attachedSessionHandshake.remoteSessionID) requested=\(remoteSessionID)"
                    )
                    throw ACPExternalAgentRuntimeError.sessionAlreadyAttached(
                        current: attachedSessionHandshake.remoteSessionID,
                        requested: remoteSessionID
                    )
                }
            }
            debugLog("ensureSession reuse attached remote=\(attachedSessionHandshake.remoteSessionID)")
            return attachedSessionHandshake
        }

        if let remoteSessionID = remoteSessionID?.nonEmptyValue,
           capabilities.loadSession {
            debugLog("ensureSession attempting restore remote=\(remoteSessionID)")
            if let handshake = try await loadSessionIfPossible(
                workingDirectory: workingDirectory,
                remoteSessionID: remoteSessionID
            ) {
                debugLog("ensureSession restored remote=\(handshake.remoteSessionID)")
                return handshake
            }
            debugLog("ensureSession restore unavailable remote=\(remoteSessionID); falling back to newSession")
        } else if let remoteSessionID = remoteSessionID?.nonEmptyValue {
            debugLog("ensureSession skip restore remote=\(remoteSessionID) reason=capability-disabled")
        }

        return try await createSession(workingDirectory: workingDirectory)
    }

    func loadSessionIfPossible(
        workingDirectory: String,
        remoteSessionID: String
    ) async throws -> ACPExternalAgentSessionHandshake? {
        let capabilities = try await initializeIfNeeded()
        guard capabilities.loadSession else {
            debugLog("loadSession skipped remote=\(remoteSessionID) reason=capability-disabled")
            return nil
        }

        if let handshake = await restoreSessionIfPossible(
            workingDirectory: workingDirectory,
            remoteSessionID: remoteSessionID,
            capabilities: capabilities
        ) {
            setAttachedSessionHandshake(handshake)
            return handshake
        }

        return nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        let capabilities = try await initializeIfNeeded()
        debugLog("createSession start cwd=\(workingDirectory)")
        let response = try await managedRuntime.runtime.newSession(
            ACPNewSessionRequest(cwd: workingDirectory)
        )
        let handshake = ACPExternalAgentSessionHandshake(
            remoteSessionID: response.sessionID,
            capabilities: capabilities,
            configurationSnapshot: Self.makeConfigurationSnapshot(
                configOptions: response.configOptions,
                modes: response.modes
            )
        )
        setAttachedSessionHandshake(handshake)
        debugLog("createSession complete remote=\(handshake.remoteSessionID)")
        return handshake
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {
        guard !modeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        debugLog("setSessionMode start session=\(sessionID) mode=\(modeID)")
        _ = try await managedRuntime.runtime.setSessionMode(
            ACPSetSessionModeRequest(meta: nil, modeID: modeID, sessionID: sessionID)
        )
        if let currentHandshake = currentAttachedSessionHandshake(),
           currentHandshake.remoteSessionID == sessionID {
            setAttachedSessionHandshake(Self.updatingMode(modeID, in: currentHandshake))
        }
        debugLog("setSessionMode complete session=\(sessionID) mode=\(modeID)")
    }

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        guard !configID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        debugLog("setSessionConfigOption start session=\(sessionID) configID=\(configID) value=\(value)")
        let response = try await managedRuntime.runtime.setSessionConfigOption(
            ACPSetSessionConfigOptionRequest(meta: nil, configID: configID, sessionID: sessionID, value: value)
        )
        if let currentHandshake = currentAttachedSessionHandshake(),
           currentHandshake.remoteSessionID == sessionID {
            setAttachedSessionHandshake(ACPExternalAgentSessionHandshake(
                remoteSessionID: currentHandshake.remoteSessionID,
                capabilities: currentHandshake.capabilities,
                configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot(
                    configOptions: response.configOptions,
                    modes: currentHandshake.configurationSnapshot.modes
                )
            ))
        }
        debugLog("setSessionConfigOption complete session=\(sessionID) configID=\(configID) count=\(response.configOptions.count)")
        return response.configOptions
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        debugLog("prompt start session=\(sessionID) textLength=\(text.count)")
        let response = try await managedRuntime.runtime.prompt(
            ACPPromptRequest(
                meta: nil,
                prompt: [.text(ACPTextContentBlock(meta: nil, annotations: nil, text: text))],
                sessionID: sessionID
            )
        )
        debugLog("prompt complete session=\(sessionID) stopReason=\(response.stopReason.rawValue)")
        return response.stopReason
    }

    func cancel(sessionID: String) async throws {
        debugLog("cancel start session=\(sessionID)")
        try await managedRuntime.runtime.cancel(ACPCancelNotification(meta: nil, sessionID: sessionID))
        debugLog("cancel complete session=\(sessionID)")
    }

    func close() async {
        let currentHandshake = currentAttachedSessionHandshake()
        debugLog(
            "close start attachedRemote=\(currentHandshake?.remoteSessionID ?? "nil") runtimeRunning=\(managedRuntime.isRunning)"
        )
        clearSessionState()
        await managedRuntime.close()
        debugLog("close complete")
    }

    private func restoreSessionIfPossible(
        workingDirectory: String,
        remoteSessionID: String,
        capabilities: ACPExternalAgentCapabilitySnapshot
    ) async -> ACPExternalAgentSessionHandshake? {
        do {
            debugLog("restore start remote=\(remoteSessionID) cwd=\(workingDirectory)")
            let response = try await loadSessionWithTimeout(
                ACPLoadSessionRequest(cwd: workingDirectory, sessionID: remoteSessionID)
            )
            debugLog("restore complete remote=\(remoteSessionID)")
            return ACPExternalAgentSessionHandshake(
                remoteSessionID: remoteSessionID,
                capabilities: capabilities,
                configurationSnapshot: Self.makeConfigurationSnapshot(
                    configOptions: response.configOptions,
                    modes: response.modes
                )
            )
        } catch {
            debugLog("restore failed remote=\(remoteSessionID) error=\(Self.describe(error))")
            return nil
        }
    }

    private func loadSessionWithTimeout(_ request: ACPLoadSessionRequest) async throws -> ACPLoadSessionResponse {
        debugLog(
            "loadSession start remote=\(request.sessionID) cwd=\(request.cwd) timeoutNs=\(loadSessionTimeoutNanoseconds)"
        )
        let runtime = managedRuntime.runtime
        let loadTask = Task {
            try await runtime.loadSession(request)
        }

        defer { loadTask.cancel() }

        let response = try await withThrowingTaskGroup(of: ACPLoadSessionResponse.self) { group in
            group.addTask {
                try await loadTask.value
            }
            group.addTask { [loadSessionTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: loadSessionTimeoutNanoseconds)
                throw ACPExternalSessionRestoreError.timedOut
            }

            guard let response = try await group.next() else {
                throw ACPRequestError.internalError(data: .object(["reason": .string("Missing loadSession response")]))
            }
            group.cancelAll()
            return response
        }
        debugLog("loadSession complete remote=\(request.sessionID)")
        return response
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        guard managedRuntime.isRunning else {
            debugLog("initialize skipped because runtime is not running")
            throw ACPExternalAgentRuntimeError.runtimeNotRunning
        }

        if let capabilitySnapshot = currentCapabilitySnapshot() {
            debugLog("initialize reuse cached capabilities")
            return capabilitySnapshot
        }

        debugLog("initialize start")
        let request = ACPInitializeRequest(
            meta: nil,
            clientCapabilities: ACPClientCapabilities(
                meta: nil,
                filesystem: ACPFileSystemCapability(meta: nil, readTextFile: true, writeTextFile: true),
                terminal: true
            ),
            clientInfo: ACPImplementation(meta: nil, name: "agentGui", title: "agentGui", version: "1.0"),
            protocolVersion: ACPMethodCatalog.protocolVersion
        )
        let response: ACPInitializeResponse
        do {
            response = try await initializeWithTimeout(request)
        } catch ACPExternalSessionRestoreError.timedOut {
            debugLog("initialize timed out after \(initializeTimeoutNanoseconds)ns")
            await managedRuntime.close()
            throw ACPExternalAgentRuntimeError.initializeTimedOut
        }

        let capabilities = ACPExternalAgentCapabilitySnapshot(
            loadSession: response.agentCapabilities?.loadSession ?? false,
            supportsSessionModelOverride: false,
            agentVersion: response.agentInfo?.version
        )
        setCapabilitySnapshot(capabilities)
        debugLog(
            "initialize complete loadSession=\(capabilities.loadSession) supportsSessionModelOverride=\(capabilities.supportsSessionModelOverride) agentVersion=\(capabilities.agentVersion ?? "nil")"
        )
        return capabilities
    }

    private func currentCapabilitySnapshot() -> ACPExternalAgentCapabilitySnapshot? {
        withStateLock { capabilitySnapshot }
    }

    private func setCapabilitySnapshot(_ snapshot: ACPExternalAgentCapabilitySnapshot?) {
        withStateLock {
            capabilitySnapshot = snapshot
        }
    }

    private func currentAttachedSessionHandshake() -> ACPExternalAgentSessionHandshake? {
        withStateLock { attachedSessionHandshake }
    }

    private func setAttachedSessionHandshake(_ handshake: ACPExternalAgentSessionHandshake?) {
        withStateLock {
            attachedSessionHandshake = handshake
        }
    }

    private func clearSessionState() {
        withStateLock {
            attachedSessionHandshake = nil
            capabilitySnapshot = nil
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func initializeWithTimeout(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        let runtime = managedRuntime.runtime
        let initializeTask = Task {
            try await runtime.initialize(request)
        }

        defer { initializeTask.cancel() }

        return try await withThrowingTaskGroup(of: ACPInitializeResponse.self) { group in
            group.addTask {
                try await initializeTask.value
            }
            group.addTask { [initializeTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: initializeTimeoutNanoseconds)
                throw ACPExternalSessionRestoreError.timedOut
            }

            guard let response = try await group.next() else {
                throw ACPRequestError.internalError(data: .object(["reason": .string("Missing initialize response")]))
            }
            group.cancelAll()
            return response
        }
    }

    private func debugLog(_ message: String) {
        if let debugLogger {
            debugLogger("[runtime-client:\(debugID)] \(message)")
        } else {
            print("[ACP][runtime-client:\(debugID)] \(message)")
        }
    }

    private static func makeDebugID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func summarize(_ message: ACPWireMessage) -> String {
        switch message {
        case .request(let request):
            return "request id=\(describe(request.id)) method=\(request.method)"
        case .notification(let notification):
            return "notification method=\(notification.method)"
        case .response(let response):
            if let error = response.error {
                return "response id=\(describe(response.id)) error=\(error.code):\(error.message)"
            }
            return "response id=\(describe(response.id)) ok"
        }
    }

    private static func describe(_ requestID: ACPRequestID) -> String {
        switch requestID {
        case .int(let value):
            return String(value)
        case .string(let value):
            return value
        }
    }

    private static func describe(_ error: Error) -> String {
        if let runtimeError = error as? ACPExternalSessionRestoreError {
            switch runtimeError {
            case .timedOut:
                return "restore-timed-out"
            }
        }

        if let requestError = error as? ACPRequestError {
            return "request-error code=\(requestError.code) message=\(requestError.message)"
        }

        return error.localizedDescription
    }
}

private extension ACPExternalAgentRuntimeClient {
    static func makeConfigurationSnapshot(
        configOptions: [ACPSessionConfigOption]?,
        modes: ACPSessionModeState?
    ) -> ACPExternalAgentSessionConfigurationSnapshot {
        ACPExternalAgentSessionConfigurationSnapshot(
            configOptions: configOptions ?? [],
            modes: modes
        )
    }

    static func updatingMode(
        _ modeID: String,
        in handshake: ACPExternalAgentSessionHandshake
    ) -> ACPExternalAgentSessionHandshake {
        guard let modes = handshake.configurationSnapshot.modes else {
            return handshake
        }

        return ACPExternalAgentSessionHandshake(
            remoteSessionID: handshake.remoteSessionID,
            capabilities: handshake.capabilities,
            configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot(
                configOptions: handshake.configurationSnapshot.configOptions,
                modes: ACPSessionModeState(
                    meta: modes.meta,
                    availableModes: modes.availableModes,
                    currentModeID: modeID
                )
            )
        )
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}