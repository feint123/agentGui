import Foundation
import SwiftData

enum OpenCodeCLIExecutionProviderError: LocalizedError {
    case unavailable(String)
    case unsupportedConfiguration

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .unsupportedConfiguration:
            return "当前仅支持 OpenCode CLI 的 ACP stdio 模式。"
        }
    }
}

@MainActor
final class OpenCodeCLIExecutionProvider: ConversationExecutionProvider {
    struct ActiveTurnState {
        let assistantMessage: Message
        let modelContext: ModelContext
    }

    let id: ConversationExecutionProviderID = .openCodeCLI

    private let runtimeFactory: OpenCodeCLIRuntimeFactory
    private let sessionBridge: CopilotSessionBridge
    private let availabilityService: OpenCodeCLIAvailabilityService
    private let terminalRuntimeFactory: (String, String?) -> TerminalTaskRuntime
    private let permissionCenter: ACPPermissionCenter
    private let authorizationPolicyFactory: ConversationAuthorizationPolicyFactory
    private let normalizer = CopilotACPEventNormalizer()

    private var runtimeClients: [String: ACPExternalAgentRuntimeClient] = [:]
    private var activeTurns: [String: ActiveTurnState] = [:]

    init(
        runtimeFactory: OpenCodeCLIRuntimeFactory = OpenCodeCLIRuntimeFactory(),
        sessionBridge: CopilotSessionBridge = CopilotSessionBridge(),
        availabilityService: OpenCodeCLIAvailabilityService = OpenCodeCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory = ConversationAuthorizationPolicyFactory()
    ) {
        self.runtimeFactory = runtimeFactory
        self.sessionBridge = sessionBridge
        self.availabilityService = availabilityService
        self.terminalRuntimeFactory = terminalRuntimeFactory
        self.permissionCenter = permissionCenter
        self.authorizationPolicyFactory = authorizationPolicyFactory
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        let settings = AppSettings.getOrCreate(in: request.modelContext)
        let configuration = SessionExecutionPreferencesResolver.openCodeCLIConfiguration(
            for: request.session,
            settings: settings
        )
        debugLog(
            "send start session=\(request.session.sessionId) textLength=\(request.text.count) executable=\(configuration.executablePath) useACPStdIO=\(configuration.useACPStdIO)"
        )
        let authorizationPolicy = authorizationPolicyFactory.makePolicy(
            from: settings,
            approvalMode: approvalMode(for: configuration)
        )
        guard configuration.useACPStdIO else {
            debugLog("send abort session=\(request.session.sessionId) unsupported configuration")
            throw OpenCodeCLIExecutionProviderError.unsupportedConfiguration
        }

        let availabilityStatus = availabilityService.quickStatus(configuration: configuration)
        guard availabilityStatus.kind == .available else {
            debugLog("send abort session=\(request.session.sessionId) availability=\(availabilityStatus.summaryText)")
            throw OpenCodeCLIExecutionProviderError.unavailable(availabilityStatus.summaryText)
        }

        let assistantMessage = Message.agentMessage(text: "", session: request.session)
        assistantMessage.status = .pending
        request.modelContext.insert(assistantMessage)
        try? request.modelContext.save()
        activeTurns[request.session.sessionId] = ActiveTurnState(assistantMessage: assistantMessage, modelContext: request.modelContext)

        do {
            let remoteBinding = await sessionBridge.binding(for: request.session.sessionId, providerID: id)
            let workingDirectory = resolvedWorkingDirectory(session: request.session, settings: settings)
            debugLog(
                "send preparing session=\(request.session.sessionId) workingDirectory=\(workingDirectory) remoteBinding=\(remoteBinding?.remoteSessionID ?? "(none)")"
            )
            let runtimeClient = try makeRuntimeClientIfNeeded(
                session: request.session,
                configuration: configuration,
                workingDirectory: workingDirectory,
                authorizationPolicy: authorizationPolicy
            )
            debugLog("ensureSession start session=\(request.session.sessionId)")
            let handshake = try await runtimeClient.ensureSession(
                workingDirectory: workingDirectory,
                remoteSessionID: trimmedNonEmpty(remoteBinding?.remoteSessionID)
            )
            debugLog(
                "ensureSession done session=\(request.session.sessionId) remote=\(handshake.remoteSessionID) loadSession=\(handshake.capabilities.loadSession) modelOverride=\(handshake.capabilities.supportsSessionModelOverride) version=\(handshake.capabilities.agentVersion ?? "(nil)")"
            )

            let selectedModel = selectedModelID(for: configuration)
            let modelOverride = handshake.capabilities.supportsSessionModelOverride ? selectedModel : nil
            if let modelOverride {
                debugLog("setModel start session=\(request.session.sessionId) model=\(modelOverride)")
                try await runtimeClient.setModel(modelOverride, sessionID: handshake.remoteSessionID)
                debugLog("setModel done session=\(request.session.sessionId) model=\(modelOverride)")
            } else {
                debugLog(
                    "setModel skipped session=\(request.session.sessionId) selectedModel=\(selectedModel ?? "(nil)") supported=\(handshake.capabilities.supportsSessionModelOverride)"
                )
            }

            await sessionBridge.upsert(
                CopilotSessionBridge.Binding(
                    sessionID: request.session.sessionId,
                    providerID: .openCodeCLI,
                    remoteSessionID: handshake.remoteSessionID,
                    cliVersion: handshake.capabilities.agentVersion,
                    negotiatedCapabilities: handshake.capabilities,
                    lastHandshakeAt: Date(),
                    lastSelectedModel: modelOverride,
                    lastSelectedAgentName: nil
                )
            )
            debugLog("binding updated session=\(request.session.sessionId) remote=\(handshake.remoteSessionID)")

            let promptText = makePromptText(
                currentText: request.text,
                session: request.session,
                remoteSessionID: remoteBinding?.remoteSessionID
            )
            debugLog("prompt start session=\(request.session.sessionId) promptLength=\(promptText.count)")
            let stopReason = try await runtimeClient.prompt(text: promptText, sessionID: handshake.remoteSessionID)
            debugLog("prompt done session=\(request.session.sessionId) stopReason=\(stopReason)")

            finalizeAssistantMessage(
                assistantMessage,
                stopReason: stopReason,
                requestText: request.text,
                session: request.session,
                modelContext: request.modelContext
            )
            debugLog("send finalized session=\(request.session.sessionId) messageStatus=\(assistantMessage.status)")
            activeTurns.removeValue(forKey: request.session.sessionId)
        } catch is CancellationError {
            debugLog("send cancelled session=\(request.session.sessionId)")
            markCancelledIfNeeded(sessionID: request.session.sessionId)
            throw CancellationError()
        } catch {
            debugLog("send failed session=\(request.session.sessionId) error=\(error.localizedDescription)")
            failAssistantMessage(
                sessionID: request.session.sessionId,
                error: error,
                modelContext: request.modelContext
            )
            throw error
        }
    }

    func regenerate(_ request: ConversationRegenerationRequest) async throws {
        let sortedMessages = request.session.messages.sorted { $0.sequence < $1.sequence }
        guard let lastUser = sortedMessages.last(where: { $0.direction == .user }),
              let lastUserText = lastUser.textContent,
              !lastUserText.isEmpty else {
            return
        }

        for message in sortedMessages where message.sequence > lastUser.sequence {
            request.modelContext.delete(message)
        }
        try? request.modelContext.save()

        await resetRuntime(for: request.session.sessionId)
        try await send(
            ConversationExecutionRequest(
                text: lastUserText,
                session: request.session,
                modelID: request.modelID,
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: request.modelContext
            )
        )
    }

    func editAndResend(_ request: ConversationEditAndResendRequest) async throws {
        request.message.textContent = request.newText

        let sortedMessages = request.session.messages.sorted { $0.sequence < $1.sequence }
        for message in sortedMessages where message.sequence > request.message.sequence {
            request.modelContext.delete(message)
        }
        try? request.modelContext.save()

        await resetRuntime(for: request.session.sessionId)
        try await send(
            ConversationExecutionRequest(
                text: request.newText,
                session: request.session,
                modelID: request.modelID,
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: request.modelContext
            )
        )
    }

    func cancel(session: Session, modelContext: ModelContext) async {
        permissionCenter.cancelRequests(for: session.sessionId)

        if let remoteSessionID = await sessionBridge.binding(for: session.sessionId, providerID: id)?.remoteSessionID,
           let runtimeClient = runtimeClients[session.sessionId] {
            try? await runtimeClient.cancel(sessionID: remoteSessionID)
        }

        if let activeTurn = activeTurns.removeValue(forKey: session.sessionId) {
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
        } else {
            _ = modelContext
        }
    }

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        _ = modelContext
        await resetRuntime(for: session.sessionId)
    }

    private func resolvedWorkingDirectory(session: Session, settings: AppSettings) -> String {
        if let sessionDirectory = trimmedNonEmpty(session.workingDirectory) {
            return sessionDirectory
        }
        if let globalDirectory = trimmedNonEmpty(settings.workingDirectory) {
            return globalDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func makeRuntimeClientIfNeeded(
        session: Session,
        configuration: OpenCodeCLIConfiguration,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy
    ) throws -> ACPExternalAgentRuntimeClient {
        if let existing = runtimeClients[session.sessionId] {
            debugLog("reuse runtime session=\(session.sessionId)")
            return existing
        }

        let launchConfiguration = runtimeFactory.makeLaunchConfiguration(
            executablePath: configuration.executablePath,
            workingDirectory: workingDirectory,
            environmentOverrides: configuration.environment
        )
        let terminalRuntime = terminalRuntimeFactory(session.sessionId, workingDirectory)
        let client = try ACPExternalAgentRuntimeClient(
            launchConfiguration: launchConfiguration,
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: makePermissionResolver(localSessionID: session.sessionId),
            eventSink: makeUpdateSink(localSessionID: session.sessionId)
        )
        debugLog(
            "created runtime session=\(session.sessionId) command=\(launchConfiguration.command) cwd=\(launchConfiguration.currentDirectoryURL.path) envCount=\(launchConfiguration.environmentOverrides.count)"
        )
        runtimeClients[session.sessionId] = client
        return client
    }

    private func makePermissionResolver(
        localSessionID: String
    ) -> @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse? {
        let permissionCenter = permissionCenter
        let source = ACPPermissionCenter.RequestSource(providerID: id, localSessionID: localSessionID)

        return { [weak self] request, policy in
            await MainActor.run {
                self?.debugLog(
                    "permission requested session=\(localSessionID) tool=\(request.toolCall.kind ?? "(nil)") title=\(request.toolCall.title ?? "(nil)") approvalMode=\(policy.approvalMode.rawValue)"
                )
            }
            let response = await permissionCenter.resolve(request: request, source: source, policy: policy)
            await MainActor.run {
                self?.applyPermissionResolution(response, request: request, localSessionID: localSessionID)
                self?.debugLog(
                    "permission resolved session=\(localSessionID) tool=\(request.toolCall.toolCallID) outcome=\(String(describing: response?.outcome))"
                )
            }
            return response
        }
    }

    private func makeUpdateSink(localSessionID: String) -> @Sendable (CopilotACPUpdate) async -> Void {
        { [weak self] update in
            guard let self else { return }
            await MainActor.run {
                self.debugLog("update received session=\(localSessionID) kind=\(self.describe(update: update))")
            }
            await self.consumeOnMain(update: update, localSessionID: localSessionID)
        }
    }

    @MainActor
    private func consumeOnMain(update: CopilotACPUpdate, localSessionID: String) {
        consume(update: update, localSessionID: localSessionID)
    }

    private func applyPermissionResolution(
        _ response: ACPRequestPermissionResponse?,
        request: ACPRequestPermissionRequest,
        localSessionID: String
    ) {
        guard let response,
              let activeTurn = activeTurns[localSessionID] else {
            return
        }

        let kind = ToolKind.classify(rawName: request.toolCall.kind)
        let toolCall = ensurePermissionToolCall(
            toolCallID: request.toolCall.toolCallID,
            kind: kind,
            title: request.toolCall.title ?? kind.displayName,
            reason: normalizer.permissionReason(in: request),
            message: activeTurn.assistantMessage,
            modelContext: activeTurn.modelContext
        )

        switch response.outcome {
        case .cancelled:
            toolCall.status = .cancelled
            toolCall.toolResultSummary = "权限请求已取消"
            toolCall.endTime = toolCall.endTime ?? Date()
        case .selected(let outcome):
            guard let option = request.options.first(where: { $0.optionID == outcome.optionID }) else {
                break
            }
            switch option.kind {
            case .rejectOnce, .rejectAlways:
                toolCall.status = .cancelled
                toolCall.toolResultSummary = "权限被拒绝"
                toolCall.endTime = toolCall.endTime ?? Date()
            case .allowOnce, .allowAlways:
                toolCall.status = .success
                toolCall.toolResultSummary = "权限已批准"
                toolCall.endTime = toolCall.endTime ?? Date()
            }
        case .other:
            break
        }

        try? activeTurn.modelContext.save()
    }

    private func consume(update: CopilotACPUpdate, localSessionID: String) {
        guard let activeTurn = activeTurns[localSessionID] else {
            debugLog("update dropped session=\(localSessionID) no active turn")
            return
        }

        let events = normalizer.normalize(update: update)
        debugLog("update normalized session=\(localSessionID) events=\(events.map(describe(event:)).joined(separator: ", "))")
        for event in events {
            apply(event: event, to: activeTurn.assistantMessage, in: activeTurn.modelContext)
        }

        try? activeTurn.modelContext.save()
    }

    private func apply(event: CopilotNormalizedEvent, to message: Message, in modelContext: ModelContext) {
        switch event {
        case .assistantTextDelta(let delta):
            message.textContent = (message.textContent ?? "") + delta
        case .thinkingDelta(let delta):
            let round = ensurePrimaryRound(for: message, in: modelContext)
            round.thinkingContent = (round.thinkingContent ?? "") + delta
        case .toolCallStarted(let id, let kind, let title, let filePath):
            let toolCall = ensureToolCall(
                toolCallID: id,
                kind: kind,
                title: title,
                filePath: filePath,
                message: message,
                modelContext: modelContext
            )
            toolCall.status = .inProgress
        case .toolCallUpdated(let id, let kind, let title, let filePath, let status, let rawOutput):
            let toolCall = ensureToolCall(
                toolCallID: id,
                kind: kind ?? .other,
                title: title,
                filePath: filePath,
                message: message,
                modelContext: modelContext
            )
            if let kind {
                toolCall.kind = kind
            }
            if let title, !title.isEmpty {
                toolCall.title = title
            }
            if let filePath, !filePath.isEmpty {
                toolCall.filePath = filePath
            }
            if let rawOutput, !rawOutput.isEmpty {
                toolCall.terminalOutput = rawOutput
            }
            if let status {
                toolCall.status = status
                if status != .inProgress {
                    toolCall.endTime = Date()
                }
            }
        case .permissionRequested(let id, let kind, let title, let reason):
            let toolCall = ensurePermissionToolCall(
                toolCallID: id,
                kind: kind,
                title: title ?? kind.displayName,
                reason: reason,
                message: message,
                modelContext: modelContext
            )
            toolCall.status = .inProgress
            toolCall.toolResultSummary = "等待权限批准"
        }
    }

    private func ensurePrimaryRound(for message: Message, in modelContext: ModelContext) -> AgentRound {
        if let existing = message.agentRounds.sorted(by: { $0.roundIndex < $1.roundIndex }).last {
            return existing
        }

        let round = AgentRound(roundIndex: message.agentRounds.count, message: message)
        modelContext.insert(round)
        return round
    }

    private func ensurePermissionToolCall(
        toolCallID: String,
        kind: ToolKind,
        title: String?,
        reason: String?,
        message: Message,
        modelContext: ModelContext
    ) -> ToolCall {
        let permissionRecordID = permissionRecordToolCallID(for: toolCallID)
        if let existing = allToolCalls(in: message).first(where: { $0.toolCallId == permissionRecordID && $0.isPermissionRequest }) {
            if let title, !title.isEmpty {
                existing.title = title
            }
            if let reason, !reason.isEmpty {
                existing.terminalOutput = reason
            }
            return existing
        }

        let round = ensurePrimaryRound(for: message, in: modelContext)
        let toolCall = ToolCall(toolCallId: permissionRecordID, kind: kind, message: message, agentRound: round)
        toolCall.isPermissionRequest = true
        toolCall.permissionTargetToolCallId = toolCallID
        toolCall.title = title
        toolCall.terminalOutput = reason
        modelContext.insert(toolCall)
        return toolCall
    }

    private func ensureToolCall(
        toolCallID: String,
        kind: ToolKind,
        title: String?,
        filePath: String?,
        message: Message,
        modelContext: ModelContext
    ) -> ToolCall {
        if let existing = allToolCalls(in: message).first(where: { $0.toolCallId == toolCallID }) {
            if let title, !title.isEmpty {
                existing.title = title
            }
            if let filePath, !filePath.isEmpty {
                existing.filePath = filePath
            }
            return existing
        }

        let round = ensurePrimaryRound(for: message, in: modelContext)
        let toolCall = ToolCall(toolCallId: toolCallID, kind: kind, message: message, agentRound: round)
        toolCall.title = title
        toolCall.filePath = filePath
        modelContext.insert(toolCall)
        return toolCall
    }

    private func allToolCalls(in message: Message) -> [ToolCall] {
        let roundCalls = message.agentRounds.flatMap(\.toolCalls)
        let directCalls = message.toolCalls.filter { $0.agentRound == nil }
        return roundCalls + directCalls
    }

    private func permissionRecordToolCallID(for toolCallID: String) -> String {
        "permission:\(toolCallID)"
    }

    private func makePromptText(currentText: String, session: Session, remoteSessionID: String?) -> String {
        guard remoteSessionID == nil || remoteSessionID?.isEmpty == true else {
            return currentText
        }

        let transcript = transcriptText(for: session, currentText: currentText)
        if transcript.components(separatedBy: "\n\n").count <= 1 {
            return currentText
        }

        return "继续下面的对话，并直接回复最后一条用户消息。不要复述整段转录。\n\n\(transcript)"
    }

    private func transcriptText(for session: Session, currentText: String) -> String {
        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        let lastPersistedMessageMatchesCurrentTurn = sortedMessages.last.map {
            $0.direction == .user && $0.textContent == currentText
        } ?? false

        var lines: [String] = []
        for message in sortedMessages {
            guard let text = message.textContent, !text.isEmpty else { continue }
            switch message.direction {
            case .user:
                lines.append("User:\n\(text)")
            case .agent:
                lines.append("Assistant:\n\(text)")
            case .system:
                continue
            }
        }

        if !lastPersistedMessageMatchesCurrentTurn {
            lines.append("User:\n\(currentText)")
        }

        return lines.joined(separator: "\n\n")
    }

    private func finalizeAssistantMessage(
        _ assistantMessage: Message,
        stopReason: ACPStopReason,
        requestText: String,
        session: Session,
        modelContext: ModelContext
    ) {
        assistantMessage.status = stopReason == .cancelled ? .cancelled : .completed
        settleOutstandingToolCalls(
            in: assistantMessage,
            terminalStatus: stopReason == .cancelled ? .cancelled : .success
        )
        if assistantMessage.textContent?.isEmpty ?? true {
            assistantMessage.textContent = stopReason == .cancelled ? "(已取消)" : "(无响应)"
        }

        if session.title == "新对话" || session.title.isEmpty {
            session.title = String(requestText.prefix(30))
        }
        session.updatedAt = Date()
        try? modelContext.save()
        debugLog("message finalized session=\(session.sessionId) stopReason=\(stopReason) textLength=\((assistantMessage.textContent ?? "").count)")
    }

    private func failAssistantMessage(sessionID: String, error: Error, modelContext: ModelContext) {
        if let activeTurn = activeTurns.removeValue(forKey: sessionID) {
            activeTurn.assistantMessage.status = .failed
            activeTurn.assistantMessage.errorMessage = error.localizedDescription
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .failed)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "错误: \(error.localizedDescription)"
            }
            try? activeTurn.modelContext.save()
            debugLog("message failed session=\(sessionID) error=\(error.localizedDescription)")
        } else {
            _ = modelContext
        }
    }

    private func markCancelledIfNeeded(sessionID: String) {
        if let activeTurn = activeTurns.removeValue(forKey: sessionID) {
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
            debugLog("message cancelled session=\(sessionID)")
        }
    }

    private func resetRuntime(for localSessionID: String) async {
        permissionCenter.cancelRequests(for: localSessionID)
        if let runtimeClient = runtimeClients.removeValue(forKey: localSessionID) {
            debugLog("reset runtime session=\(localSessionID)")
            await runtimeClient.close()
        }
        await sessionBridge.removeBinding(for: localSessionID, providerID: id)
        activeTurns.removeValue(forKey: localSessionID)
    }

    private func approvalMode(for configuration: OpenCodeCLIConfiguration) -> ToolApprovalMode {
        switch configuration.defaultApprovalMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "never":
            return .none
        case "auto", "automatic", "always":
            return .subjectPolicy
        default:
            return .alwaysRequireHuman
        }
    }

    private func selectedModelID(for configuration: OpenCodeCLIConfiguration) -> String? {
        trimmedNonEmpty(configuration.defaultModel)
    }

    private func settleOutstandingToolCalls(in message: Message, terminalStatus: ToolStatus) {
        let settledAt = Date()
        for toolCall in allToolCalls(in: message) where toolCall.status == .inProgress {
            toolCall.status = terminalStatus
            if toolCall.endTime == nil {
                toolCall.endTime = settledAt
            }
        }
    }

    private func debugLog(_ message: String) {
        print("[opencode] \(message)")
    }

    private func describe(update: CopilotACPUpdate) -> String {
        switch update {
        case .permission(let request):
            return "permission:\(request.toolCall.kind ?? "(nil)")#\(request.toolCall.toolCallID)"
        case .session(let sessionUpdate):
            switch sessionUpdate {
            case .agentMessageChunk:
                return "session:agent_message_chunk"
            case .agentThoughtChunk:
                return "session:agent_thought_chunk"
            case .toolCall(let toolCall):
                return "session:tool_call:\(toolCall.kind ?? "(nil)")#\(toolCall.toolCallID)"
            case .toolCallUpdate(let payload):
                return "session:tool_call_update:\(payload.kind ?? "(nil)")#\(payload.toolCallID)"
            default:
                return "session:other"
            }
        }
    }

    private func describe(event: CopilotNormalizedEvent) -> String {
        switch event {
        case .assistantTextDelta(let delta):
            return "assistant:\(delta.count)chars"
        case .thinkingDelta(let delta):
            return "thinking:\(delta.count)chars"
        case .toolCallStarted(let id, let kind, _, _):
            return "tool_started:\(kind.rawValue)#\(id)"
        case .toolCallUpdated(let id, let kind, _, _, let status, _):
            return "tool_updated:\((kind ?? .other).rawValue)#\(id):\(status?.rawValue ?? "(nil)")"
        case .permissionRequested(let id, let kind, _, _):
            return "permission:\(kind.rawValue)#\(id)"
        }
    }
}

private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}