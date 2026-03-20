import Foundation

enum ACPExternalAgentRuntimeError: LocalizedError {
    case sessionAlreadyAttached(current: String, requested: String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyAttached(let current, let requested):
            return "当前外部 ACP 运行时已绑定会话 \(current)，不能在同一运行时内切换到 \(requested)。"
        }
    }
}

struct ACPExternalAgentLaunchConfiguration: Equatable, Sendable {
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

struct ACPExternalAgentCapabilitySnapshot: Codable, Equatable, Sendable {
    let loadSession: Bool
    let supportsSessionModelOverride: Bool
    let agentVersion: String?
}

struct ACPExternalAgentSessionHandshake: Codable, Equatable, Sendable {
    let remoteSessionID: String
    let capabilities: ACPExternalAgentCapabilitySnapshot
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
        await eventSink(.session(notification.update))
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

@MainActor
final class ACPExternalAgentRuntimeClient {
    private let managedRuntime: ACPManagedClientRuntime
    private let supportsSessionModelOverrideFallback: Bool
    private var capabilitySnapshot: ACPExternalAgentCapabilitySnapshot?
    private var attachedSessionHandshake: ACPExternalAgentSessionHandshake?

    init(
        launchConfiguration: ACPExternalAgentLaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        supportsSessionModelOverrideFallback: Bool = false,
        permissionResolver: (@Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)? = nil,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws {
        self.supportsSessionModelOverrideFallback = supportsSessionModelOverrideFallback
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
            clientHandler: handler
        )
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake {
        let capabilities = try await initializeIfNeeded()

        if let attachedSessionHandshake {
            if let remoteSessionID = remoteSessionID?.nonEmptyValue {
                guard attachedSessionHandshake.remoteSessionID == remoteSessionID else {
                    throw ACPExternalAgentRuntimeError.sessionAlreadyAttached(
                        current: attachedSessionHandshake.remoteSessionID,
                        requested: remoteSessionID
                    )
                }
            }
            return attachedSessionHandshake
        }

        if let remoteSessionID = remoteSessionID?.nonEmptyValue,
           capabilities.loadSession {
            _ = try await managedRuntime.runtime.loadSession(
                ACPLoadSessionRequest(cwd: workingDirectory, sessionID: remoteSessionID)
            )
            let handshake = ACPExternalAgentSessionHandshake(remoteSessionID: remoteSessionID, capabilities: capabilities)
            attachedSessionHandshake = handshake
            return handshake
        }

        let response = try await managedRuntime.runtime.newSession(
            ACPNewSessionRequest(cwd: workingDirectory)
        )
        let handshake = ACPExternalAgentSessionHandshake(remoteSessionID: response.sessionID, capabilities: capabilities)
        attachedSessionHandshake = handshake
        return handshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try await managedRuntime.runtime.setSessionModel(
            ACPSetSessionModelRequest(modelID: modelID, sessionID: sessionID)
        )
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        let response = try await managedRuntime.runtime.prompt(
            ACPPromptRequest(
                meta: nil,
                prompt: [.text(ACPTextContentBlock(meta: nil, annotations: nil, text: text))],
                sessionID: sessionID
            )
        )
        return response.stopReason
    }

    func cancel(sessionID: String) async throws {
        try await managedRuntime.runtime.cancel(ACPCancelNotification(meta: nil, sessionID: sessionID))
    }

    func close() async {
        attachedSessionHandshake = nil
        capabilitySnapshot = nil
        await managedRuntime.close()
    }

    private func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        if let capabilitySnapshot {
            return capabilitySnapshot
        }

        let response = try await managedRuntime.runtime.initialize(
            ACPInitializeRequest(
                meta: nil,
                clientCapabilities: ACPClientCapabilities(
                    meta: nil,
                    filesystem: ACPFileSystemCapability(meta: nil, readTextFile: true, writeTextFile: true),
                    terminal: true
                ),
                clientInfo: ACPImplementation(meta: nil, name: "agentGui", title: "agentGui", version: "1.0"),
                protocolVersion: ACPMethodCatalog.protocolVersion
            )
        )

        let capabilities = ACPExternalAgentCapabilitySnapshot(
            loadSession: response.agentCapabilities?.loadSession ?? false,
            supportsSessionModelOverride: response.agentCapabilities?.sessionCapabilities != nil || supportsSessionModelOverrideFallback,
            agentVersion: response.agentInfo?.version
        )
        capabilitySnapshot = capabilities
        return capabilities
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}