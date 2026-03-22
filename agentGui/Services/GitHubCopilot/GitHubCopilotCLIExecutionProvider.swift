import Foundation
import SwiftData

enum GitHubCopilotCLIExecutionProviderError: LocalizedError {
    case unavailable(String)
    case unsupportedConfiguration
    case sessionAlreadyAttached(current: String, requested: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .unsupportedConfiguration:
            return "当前仅支持 GitHub Copilot CLI 的 ACP stdio 模式。"
        case .sessionAlreadyAttached(let current, let requested):
            return "当前 Copilot 运行时已绑定会话 \(current)，不能在同一运行时内切换到 \(requested)。"
        }
    }
}

struct GitHubCopilotCLISessionHandshake: Equatable, Sendable {
    let remoteSessionID: String
    let cliVersion: String?
}

@MainActor
protocol GitHubCopilotCLIRuntimeClient: AnyObject {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> GitHubCopilotCLISessionHandshake
    func setModel(_ modelID: String, sessionID: String) async throws
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

typealias GitHubCopilotCLIRuntimeClientFactory = @MainActor (
    GitHubCopilotCLILaunchConfiguration,
    TerminalTaskRuntime,
    ToolAuthorizationPolicy,
    @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
    @escaping @Sendable (CopilotACPUpdate) async -> Void
) throws -> any GitHubCopilotCLIRuntimeClient

@MainActor
final class GitHubCopilotCLIExecutionProvider: ConversationExecutionProvider {
    struct ActiveTurnState {
        let assistantMessage: Message
        let modelContext: ModelContext
    }

    let id: ConversationExecutionProviderID = .githubCopilotCLI
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    private let runtimeFactory: GitHubCopilotCLIRuntimeFactory
    private let sessionBridge: CopilotSessionBridge
    private let availabilityService: GitHubCopilotCLIAvailabilityService
    private let terminalRuntimeFactory: (String, String?) -> TerminalTaskRuntime
    private let sessionRuntimeResetter: @MainActor (String) -> Void
    private let runtimeClientFactory: GitHubCopilotCLIRuntimeClientFactory
    private let permissionCenter: ACPPermissionCenter
    private let authorizationPolicyFactory: ConversationAuthorizationPolicyFactory
    private let normalizer = CopilotACPEventNormalizer()
    private let updateProjector = ACPExternalUpdateProjector()
    private let turnRouter = ACPExternalSessionTurnRouter()

    private var runtimeClients: [String: any GitHubCopilotCLIRuntimeClient] = [:]
    private var runtimeWorkingDirectories: [String: String] = [:]
    private var activeTurns: [String: ActiveTurnState] = [:]

    init(
        runtimeFactory: GitHubCopilotCLIRuntimeFactory = GitHubCopilotCLIRuntimeFactory(),
        sessionBridge: CopilotSessionBridge = CopilotSessionBridge(),
        availabilityService: GitHubCopilotCLIAvailabilityService = GitHubCopilotCLIAvailabilityService(),
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void = { _ in },
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory = ConversationAuthorizationPolicyFactory(),
        runtimeClientFactory: @escaping GitHubCopilotCLIRuntimeClientFactory = ACPGitHubCopilotCLIRuntimeClient.make
    ) {
        self.runtimeFactory = runtimeFactory
        self.sessionBridge = sessionBridge
        self.availabilityService = availabilityService
        self.terminalRuntimeFactory = terminalRuntimeFactory
        self.sessionRuntimeResetter = sessionRuntimeResetter
        self.permissionCenter = permissionCenter
        self.authorizationPolicyFactory = authorizationPolicyFactory
        self.runtimeClientFactory = runtimeClientFactory
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        let settings = AppSettings.getOrCreate(in: request.modelContext)
        let configuration = settings.githubCopilotCLIConfiguration
        let authorizationPolicy = authorizationPolicyFactory.makePolicy(
            from: settings,
            approvalMode: approvalMode(for: configuration)
        )
        guard configuration.useACPStdIO else {
            throw GitHubCopilotCLIExecutionProviderError.unsupportedConfiguration
        }

        let availabilityStatus = availabilityService.quickStatus(configuration: configuration)
        guard availabilityStatus.kind == .available else {
            throw GitHubCopilotCLIExecutionProviderError.unavailable(availabilityStatus.summaryText)
        }

        do {
            let remoteBinding = await resolvedBinding(
                for: request.session.sessionId,
                modelContext: request.modelContext
            )
            let workingDirectory = resolvedWorkingDirectory(
                session: request.session,
                settings: settings,
                override: request.workingDirectoryOverride
            )
            await prepareForActivation(
                session: request.session,
                isActiveProvider: true,
                modelContext: request.modelContext
            )
            let runtimeClient = try await makeRuntimeClientIfNeeded(
                session: request.session,
                configuration: configuration,
                workingDirectory: workingDirectory,
                authorizationPolicy: authorizationPolicy
            )
            turnRouter.beginRestore(sessionID: request.session.sessionId)
            let handshake = try await runtimeClient.ensureSession(
                workingDirectory: workingDirectory,
                remoteSessionID: remoteBinding?.remoteSessionID.nonEmptyValue
            )
            turnRouter.finishRestore(sessionID: request.session.sessionId)

            let selectedModel = selectedModelID(for: configuration)
            if let selectedModel {
                try await runtimeClient.setModel(selectedModel, sessionID: handshake.remoteSessionID)
            }

            await persistBinding(
                sessionID: request.session.sessionId,
                remoteSessionID: handshake.remoteSessionID,
                cliVersion: handshake.cliVersion,
                selectedModel: selectedModel,
                selectedAgentName: configuration.customAgentName,
                modelContext: request.modelContext
            )

            let promptText = makePromptText(
                currentText: request.text,
                session: request.session,
                remoteSessionID: remoteBinding?.remoteSessionID
            )
            let assistantMessage = resolveAssistantMessage(for: request)
            updateProjector.reset(sessionID: request.session.sessionId)
            activeTurns[request.session.sessionId] = ActiveTurnState(
                assistantMessage: assistantMessage,
                modelContext: request.modelContext
            )
            turnRouter.beginLiveTurn(sessionID: request.session.sessionId)
            let stopReason = try await runtimeClient.prompt(text: promptText, sessionID: handshake.remoteSessionID)

            flushProjectedUpdates(for: request.session.sessionId)

            finalizeAssistantMessage(
                assistantMessage,
                stopReason: stopReason,
                requestText: request.text,
                session: request.session,
                modelContext: request.modelContext
            )
            activeTurns.removeValue(forKey: request.session.sessionId)
            turnRouter.finishLiveTurn(sessionID: request.session.sessionId)
        } catch is CancellationError {
            turnRouter.reset(sessionID: request.session.sessionId)
            flushProjectedUpdates(for: request.session.sessionId)
            updateProjector.reset(sessionID: request.session.sessionId)
            markCancelledIfNeeded(sessionID: request.session.sessionId)
            throw CancellationError()
        } catch {
            turnRouter.reset(sessionID: request.session.sessionId)
            flushProjectedUpdates(for: request.session.sessionId)
            updateProjector.reset(sessionID: request.session.sessionId)
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

        await resetRuntime(for: request.session.sessionId, modelContext: request.modelContext)
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

        await resetRuntime(for: request.session.sessionId, modelContext: request.modelContext)
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
        turnRouter.reset(sessionID: session.sessionId)

        if let remoteSessionID = await sessionBridge.binding(for: session.sessionId, providerID: id)?.remoteSessionID,
           let runtimeClient = runtimeClients[session.sessionId] {
            try? await runtimeClient.cancel(sessionID: remoteSessionID)
        }

        if let activeTurn = activeTurns[session.sessionId] {
            flushProjectedUpdates(for: session.sessionId)
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
            activeTurns.removeValue(forKey: session.sessionId)
        } else {
            _ = modelContext
        }
        updateProjector.reset(sessionID: session.sessionId)
    }

    func resetSessionState(session: Session, modelContext: ModelContext) async {
        await resetRuntime(for: session.sessionId, modelContext: modelContext)
    }

    func prepareForActivation(
        session: Session,
        isActiveProvider: Bool,
        modelContext: ModelContext
    ) async {
        if isActiveProvider {
            await closeInactiveSessionRuntimes(keeping: session.sessionId)
        } else {
            await deactivateAllSessionRuntimes()
        }
        _ = modelContext
    }

    private func resolvedWorkingDirectory(
        session: Session,
        settings: AppSettings,
        override: String?
    ) -> String {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        if let sessionDirectory = session.workingDirectory.nonEmptyValue {
            return sessionDirectory
        }
        if let globalDirectory = settings.workingDirectory.nonEmptyValue {
            return globalDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func makeRuntimeClientIfNeeded(
        session: Session,
        configuration: GitHubCopilotCLIConfiguration,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy
    ) async throws -> any GitHubCopilotCLIRuntimeClient {
        if let existing = runtimeClients[session.sessionId] {
            if runtimeWorkingDirectories[session.sessionId] == workingDirectory {
                return existing
            }

            await existing.close()
            runtimeClients.removeValue(forKey: session.sessionId)
            runtimeWorkingDirectories.removeValue(forKey: session.sessionId)
            sessionRuntimeResetter(session.sessionId)
        }

        let launchConfiguration = runtimeFactory.makeLaunchConfiguration(
            executablePath: configuration.executablePath,
            workingDirectory: workingDirectory
        )
        let terminalRuntime = terminalRuntimeFactory(session.sessionId, workingDirectory)
        let client = try runtimeClientFactory(
            launchConfiguration,
            terminalRuntime,
            authorizationPolicy,
            makePermissionResolver(localSessionID: session.sessionId),
            makeUpdateSink(localSessionID: session.sessionId)
        )
        runtimeClients[session.sessionId] = client
        runtimeWorkingDirectories[session.sessionId] = workingDirectory
        return client
    }

    private func makePermissionResolver(
        localSessionID: String
    ) -> @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse? {
        let permissionCenter = permissionCenter
        let source = ACPPermissionCenter.RequestSource(providerID: id, localSessionID: localSessionID)

        return { [weak self] request, policy in
            let response = await permissionCenter.resolve(request: request, source: source, policy: policy)
            await MainActor.run {
                self?.applyPermissionResolution(response, request: request, localSessionID: localSessionID)
            }
            return response
        }
    }

    private func makeUpdateSink(localSessionID: String) -> @Sendable (CopilotACPUpdate) async -> Void {
        { [weak self] update in
            guard let self else { return }
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
        guard turnRouter.shouldProjectIncomingUpdate(for: localSessionID) else {
            return
        }

        guard let activeTurn = activeTurns[localSessionID] else {
            return
        }

        let projectedEvents = updateProjector.project(
            events: normalizer.normalize(update: update),
            sessionID: localSessionID
        )

        for event in projectedEvents {
            apply(event: event, to: activeTurn.assistantMessage, in: activeTurn.modelContext)
        }

        try? activeTurn.modelContext.save()
    }

    private func flushProjectedUpdates(for sessionID: String) {
        guard let activeTurn = activeTurns[sessionID] else {
            updateProjector.reset(sessionID: sessionID)
            return
        }

        let pendingEvents = updateProjector.flush(sessionID: sessionID)
        guard !pendingEvents.isEmpty else {
            return
        }

        for event in pendingEvents {
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
        message.agentRounds.append(round)
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
        round.toolCalls.append(toolCall)
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
        round.toolCalls.append(toolCall)
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

    private func resolveAssistantMessage(for request: ConversationExecutionRequest) -> Message {
        if let targetAgentMessageID = request.targetAgentMessageID,
           let assistantMessage = request.session.messages.first(where: { $0.id == targetAgentMessageID }) {
            assistantMessage.status = .pending
            assistantMessage.errorMessage = nil
            if assistantMessage.textContent == nil {
                assistantMessage.textContent = ""
            }
            try? request.modelContext.save()
            return assistantMessage
        }

        return makePendingAssistantMessage(session: request.session, modelContext: request.modelContext)
    }

    private func makePendingAssistantMessage(session: Session, modelContext: ModelContext) -> Message {
        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()
        return assistantMessage
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
        } else {
            _ = modelContext
        }
    }

    private func resolvedBinding(
        for localSessionID: String,
        modelContext: ModelContext
    ) async -> CopilotSessionBridge.Binding? {
        if let bridgeBinding = await sessionBridge.binding(for: localSessionID, providerID: id) {
            return bridgeBinding
        }

        guard let storedBinding = try? bindingStore(in: modelContext).binding(for: localSessionID, providerID: id),
              let remoteSessionID = storedBinding.remoteSessionID.nonEmptyValue else {
            return nil
        }

        let bridgeBinding = CopilotSessionBridge.Binding(
            sessionID: localSessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            cliVersion: storedBinding.agentVersion.nonEmptyValue,
            negotiatedCapabilities: storedBinding.negotiatedCapabilities,
            lastHandshakeAt: storedBinding.lastHandshakeAt,
            lastSelectedModel: storedBinding.lastSelectedModel.nonEmptyValue,
            lastSelectedAgentName: storedBinding.lastSelectedAgentName.nonEmptyValue
        )
        await sessionBridge.upsert(bridgeBinding)
        return bridgeBinding
    }

    private func persistBinding(
        sessionID: String,
        remoteSessionID: String,
        cliVersion: String?,
        selectedModel: String?,
        selectedAgentName: String?,
        modelContext: ModelContext
    ) async {
        let binding = CopilotSessionBridge.Binding(
            sessionID: sessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            cliVersion: cliVersion,
            negotiatedCapabilities: nil,
            lastHandshakeAt: Date(),
            lastSelectedModel: selectedModel,
            lastSelectedAgentName: selectedAgentName
        )
        await sessionBridge.upsert(binding)
        _ = try? bindingStore(in: modelContext).upsert(
            sessionID: sessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            agentVersion: cliVersion,
            capabilities: nil,
            selectedModel: selectedModel,
            selectedAgentName: selectedAgentName
        )
    }

    private func markCancelledIfNeeded(sessionID: String) {
        if let activeTurn = activeTurns.removeValue(forKey: sessionID) {
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
        }
    }

    private func closeInactiveSessionRuntimes(keeping localSessionID: String) async {
        let inactiveSessionIDs = runtimeClients.keys.filter { $0 != localSessionID }
        for inactiveSessionID in inactiveSessionIDs {
            permissionCenter.cancelRequests(for: inactiveSessionID)
            if let runtimeClient = runtimeClients.removeValue(forKey: inactiveSessionID) {
                await runtimeClient.close()
            }
            runtimeWorkingDirectories.removeValue(forKey: inactiveSessionID)
            sessionRuntimeResetter(inactiveSessionID)
            turnRouter.reset(sessionID: inactiveSessionID)
            markCancelledIfNeeded(sessionID: inactiveSessionID)
        }
    }

    private func deactivateAllSessionRuntimes() async {
        let activeSessionIDs = Array(runtimeClients.keys)
        for activeSessionID in activeSessionIDs {
            permissionCenter.cancelRequests(for: activeSessionID)
            if let runtimeClient = runtimeClients.removeValue(forKey: activeSessionID) {
                await runtimeClient.close()
            }
            runtimeWorkingDirectories.removeValue(forKey: activeSessionID)
            sessionRuntimeResetter(activeSessionID)
            turnRouter.reset(sessionID: activeSessionID)
            markCancelledIfNeeded(sessionID: activeSessionID)
        }
    }

    private func resetRuntime(
        for localSessionID: String,
        modelContext: ModelContext,
        removeBinding: Bool = true
    ) async {
        permissionCenter.cancelRequests(for: localSessionID)
        turnRouter.reset(sessionID: localSessionID)
        if let runtimeClient = runtimeClients.removeValue(forKey: localSessionID) {
            await runtimeClient.close()
        }
        runtimeWorkingDirectories.removeValue(forKey: localSessionID)
        sessionRuntimeResetter(localSessionID)
        if removeBinding {
            await sessionBridge.removeBinding(for: localSessionID, providerID: id)
            try? bindingStore(in: modelContext).removeBinding(for: localSessionID, providerID: id)
        }
        activeTurns.removeValue(forKey: localSessionID)
    }

    private func bindingStore(in modelContext: ModelContext) -> ACPExternalSessionBindingStore {
        ACPExternalSessionBindingStore(modelContext: modelContext)
    }

    private func approvalMode(for configuration: GitHubCopilotCLIConfiguration) -> ToolApprovalMode {
        ToolApprovalMode.resolved(from: configuration.defaultApprovalMode)
    }

    private func selectedModelID(for configuration: GitHubCopilotCLIConfiguration) -> String? {
        configuration.defaultModel.nonEmptyValue
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
}

private actor GitHubCopilotCLIClientHandler: ACPClientHandler {
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
final class ACPGitHubCopilotCLIRuntimeClient: GitHubCopilotCLIRuntimeClient {
    private let managedRuntime: ACPManagedClientRuntime
    private var initializedVersion: String?
    private var attachedSessionHandshake: GitHubCopilotCLISessionHandshake?

    init(
        launchConfiguration: GitHubCopilotCLILaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: (@Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?)? = nil,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws {
        let allowedRoot = launchConfiguration.currentDirectoryURL.standardizedFileURL
        let handler = GitHubCopilotCLIClientHandler(
            allowedRoots: [allowedRoot],
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
        self.managedRuntime = try ACPManagedClientRuntime.launch(
            command: launchConfiguration.command,
            arguments: launchConfiguration.arguments,
            currentDirectoryURL: launchConfiguration.currentDirectoryURL,
            clientHandler: handler
        )
    }

    static func make(
        launchConfiguration: GitHubCopilotCLILaunchConfiguration,
        terminalRuntime: TerminalTaskRuntime,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        eventSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) throws -> any GitHubCopilotCLIRuntimeClient {
        try ACPGitHubCopilotCLIRuntimeClient(
            launchConfiguration: launchConfiguration,
            terminalRuntime: terminalRuntime,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: permissionResolver,
            eventSink: eventSink
        )
    }

    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> GitHubCopilotCLISessionHandshake {
        try await initializeIfNeeded()

        if let attachedSessionHandshake {
            if let remoteSessionID = remoteSessionID?.nonEmptyValue {
                guard attachedSessionHandshake.remoteSessionID == remoteSessionID else {
                    throw GitHubCopilotCLIExecutionProviderError.sessionAlreadyAttached(
                        current: attachedSessionHandshake.remoteSessionID,
                        requested: remoteSessionID
                    )
                }
            }
            return attachedSessionHandshake
        }

        if let remoteSessionID = remoteSessionID?.nonEmptyValue {
            _ = try await managedRuntime.runtime.loadSession(
                ACPLoadSessionRequest(cwd: workingDirectory, sessionID: remoteSessionID)
            )
            let handshake = GitHubCopilotCLISessionHandshake(remoteSessionID: remoteSessionID, cliVersion: initializedVersion)
            attachedSessionHandshake = handshake
            return handshake
        }

        let response = try await managedRuntime.runtime.newSession(
            ACPNewSessionRequest(cwd: workingDirectory)
        )
        let handshake = GitHubCopilotCLISessionHandshake(remoteSessionID: response.sessionID, cliVersion: initializedVersion)
        attachedSessionHandshake = handshake
        return handshake
    }

    func setModel(_ modelID: String, sessionID: String) async throws {
        guard !modelID.isEmpty else { return }
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
        initializedVersion = nil
        await managedRuntime.close()
    }

    private func initializeIfNeeded() async throws {
        guard initializedVersion == nil else { return }

        let response = try await managedRuntime.runtime.initialize(
            ACPInitializeRequest(
                meta: nil,
                clientCapabilities: ACPClientCapabilities(
                    meta: nil,
                    filesystem: ACPFileSystemCapability(meta: nil, readTextFile: true, writeTextFile: true),
                    terminal: true
                ),
                clientInfo: ACPImplementation(meta: nil, name: "agentGui", title: "agentGui", version: "1.0"),
                protocolVersion: 1
            )
        )
        initializedVersion = response.agentInfo?.version
    }
}

private extension String {
    var nonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}