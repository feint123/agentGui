import Foundation
import SwiftData

@MainActor
class ACPExternalExecutionProviderBase<Configuration>: ConversationExecutionProvider {
    struct ActiveTurnState {
        let assistantMessage: Message
        let modelContext: ModelContext
    }

    let id: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    private let sessionBridge: CopilotSessionBridge
    private let terminalRuntimeFactory: (String, String?) -> TerminalTaskRuntime
    private let sessionRuntimeResetter: @MainActor (String) -> Void
    private let permissionCenter: ACPPermissionCenter
    private let authorizationPolicyFactory: ConversationAuthorizationPolicyFactory
    private let normalizer = CopilotACPEventNormalizer()
    private let featureExtractor = ACPExternalSessionFeatureExtractor()
    private let updateProjector = ACPExternalUpdateProjector()
    private let turnRouter = ACPExternalSessionTurnRouter()
    private let featureAdapter: ACPExternalProviderFeatureAdapter

    private var runtimeClients: [String: any ACPExternalProviderRuntimeClient] = [:]
    private var runtimeWorkingDirectories: [String: String] = [:]
    private var activeTurns: [String: ActiveTurnState] = [:]
    private var featureStores: [String: ACPExternalSessionFeatureStore] = [:]
    private var remoteSessionIDs: [String: String] = [:]
    private var sessionContexts: [String: ModelContext] = [:]
    private var pendingUpdateTasks: [String: Task<Void, Never>] = [:]
    private var pendingUpdateTaskTokens: [String: UUID] = [:]

    init(
        providerID: ConversationExecutionProviderID,
        sessionBridge: CopilotSessionBridge,
        terminalRuntimeFactory: @escaping (String, String?) -> TerminalTaskRuntime,
        sessionRuntimeResetter: @escaping @MainActor (String) -> Void,
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory,
        featureAdapter: ACPExternalProviderFeatureAdapter = ACPExternalProviderFeatureAdapter()
    ) {
        self.id = providerID
        self.sessionBridge = sessionBridge
        self.terminalRuntimeFactory = terminalRuntimeFactory
        self.sessionRuntimeResetter = sessionRuntimeResetter
        self.permissionCenter = permissionCenter
        self.authorizationPolicyFactory = authorizationPolicyFactory
        self.featureAdapter = featureAdapter
    }

    private func debugLog(_ message: String) {
        print("[ACP][\(id.rawValue)] \(message)")
    }

    func send(_ request: ConversationExecutionRequest) async throws {
        let settings = AppSettings.getOrCreate(in: request.modelContext)
        let configuration = resolveConfiguration(for: request.session, settings: settings)
        let authorizationPolicy = authorizationPolicyFactory.makePolicy(
            from: settings,
            approvalMode: approvalMode(for: configuration)
        )

        guard useACPStdIO(configuration: configuration) else {
            throw unsupportedConfigurationError()
        }

        let availabilityStatus = quickAvailabilityStatus(configuration: configuration)
        guard availabilityStatus.kind == .available else {
            throw unavailableError(summary: availabilityStatus.summaryText)
        }

        do {
            await closeInactiveSessionRuntimes(keeping: request.session.sessionId)

            let activation = try await ensureRemoteSessionPrepared(
                session: request.session,
                configuration: configuration,
                settings: settings,
                modelContext: request.modelContext,
                authorizationPolicy: authorizationPolicy,
                workingDirectoryOverride: request.workingDirectoryOverride
            )
            let remoteBinding = activation.remoteBinding
            let handshake = activation.handshake
            let runtimeClient = activation.runtimeClient

            let modelOverride = selectedModelOverride(for: configuration, handshake: handshake)
            if let modelOverride {
                try await runtimeClient.setModel(modelOverride, sessionID: handshake.remoteSessionID)
            }

            await persistBinding(
                sessionID: request.session.sessionId,
                remoteSessionID: handshake.remoteSessionID,
                configuration: configuration,
                handshake: handshake,
                selectedModel: modelOverride,
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
            await drainPendingUpdates(localSessionID: request.session.sessionId)

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
        debugLog(
            "prepareForActivation start localSession=\(session.sessionId) isActive=\(isActiveProvider)"
        )
        if isActiveProvider {
            await closeInactiveSessionRuntimes(keeping: session.sessionId)
        } else {
            await deactivateAllSessionRuntimes()
        }

        guard isActiveProvider else {
            debugLog("prepareForActivation skipped because provider is inactive localSession=\(session.sessionId)")
            return
        }

        let settings = AppSettings.getOrCreate(in: modelContext)
        let configuration = resolveConfiguration(for: session, settings: settings)
        guard useACPStdIO(configuration: configuration) else {
            debugLog("prepareForActivation skipped because ACP stdio is disabled localSession=\(session.sessionId)")
            return
        }

        let availabilityStatus = quickAvailabilityStatus(configuration: configuration)
        guard availabilityStatus.kind == .available else {
            debugLog(
                "prepareForActivation skipped because provider unavailable localSession=\(session.sessionId) summary=\(availabilityStatus.summaryText)"
            )
            return
        }

        let authorizationPolicy = authorizationPolicyFactory.makePolicy(
            from: settings,
            approvalMode: approvalMode(for: configuration)
        )

        do {
            let activation = try await ensureRemoteSessionPrepared(
                session: session,
                configuration: configuration,
                settings: settings,
                modelContext: modelContext,
                authorizationPolicy: authorizationPolicy,
                workingDirectoryOverride: nil
            )
            debugLog(
                "prepareForActivation finished localSession=\(session.sessionId) remoteSession=\(activation.handshake.remoteSessionID) reusedBinding=\(activation.remoteBinding != nil)"
            )
        } catch {
            debugLog(
                "prepareForActivation failed localSession=\(session.sessionId) error=\(String(describing: error))"
            )
        }
    }

    func resolveConfiguration(for session: Session, settings: AppSettings) -> Configuration {
        fatalError("Subclasses must override resolveConfiguration")
    }

    func useACPStdIO(configuration: Configuration) -> Bool {
        fatalError("Subclasses must override useACPStdIO")
    }

    func unsupportedConfigurationError() -> Error {
        fatalError("Subclasses must override unsupportedConfigurationError")
    }

    func quickAvailabilityStatus(configuration: Configuration) -> ACPCLIAvailabilityStatus {
        fatalError("Subclasses must override quickAvailabilityStatus")
    }

    func unavailableError(summary: String) -> Error {
        fatalError("Subclasses must override unavailableError")
    }

    func approvalMode(for configuration: Configuration) -> ToolApprovalMode {
        fatalError("Subclasses must override approvalMode")
    }

    func buildRuntimeClient(
        configuration: Configuration,
        session: Session,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeClient {
        fatalError("Subclasses must override buildRuntimeClient")
    }

    func selectedModelOverride(
        for configuration: Configuration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> String? {
        fatalError("Subclasses must override selectedModelOverride")
    }

    func persistBinding(
        sessionID: String,
        remoteSessionID: String,
        configuration: Configuration,
        handshake: ACPExternalAgentSessionHandshake,
        selectedModel: String?,
        modelContext: ModelContext
    ) async {
        await persistBindingRecord(
            sessionID: sessionID,
            remoteSessionID: remoteSessionID,
            capabilities: handshake.capabilities,
            selectedModel: selectedModel,
            selectedAgentName: nil,
            modelContext: modelContext
        )
    }

    func resolvedWorkingDirectory(
        session: Session,
        settings: AppSettings,
        override: String?
    ) -> String {
        if let override = trimmedNonEmpty(override) {
            return override
        }
        if let sessionDirectory = trimmedNonEmpty(session.workingDirectory) {
            return sessionDirectory
        }
        if let globalDirectory = trimmedNonEmpty(settings.workingDirectory) {
            return globalDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    func persistBindingRecord(
        sessionID: String,
        remoteSessionID: String,
        capabilities: ACPExternalAgentCapabilitySnapshot,
        selectedModel: String?,
        selectedAgentName: String?,
        modelContext: ModelContext
    ) async {
        let binding = CopilotSessionBridge.Binding(
            sessionID: sessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            cliVersion: capabilities.agentVersion,
            negotiatedCapabilities: capabilities,
            lastHandshakeAt: Date(),
            lastSelectedModel: selectedModel,
            lastSelectedAgentName: selectedAgentName
        )
        await sessionBridge.upsert(binding)
        _ = try? bindingStore(in: modelContext).upsert(
            sessionID: sessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            agentVersion: capabilities.agentVersion,
            capabilities: capabilities,
            selectedModel: selectedModel,
            selectedAgentName: selectedAgentName
        )
    }

    func makeTerminalRuntime(sessionID: String, workingDirectory: String) -> TerminalTaskRuntime {
        terminalRuntimeFactory(sessionID, workingDirectory)
    }

    private func makeRuntimeClientIfNeeded(
        session: Session,
        configuration: Configuration,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy
    ) async throws -> RuntimeClientAcquisition {
        if let existing = runtimeClients[session.sessionId] {
            if runtimeWorkingDirectories[session.sessionId] == workingDirectory {
                debugLog(
                    "runtimeClient reuse localSession=\(session.sessionId) workingDirectory=\(workingDirectory)"
                )
                return RuntimeClientAcquisition(
                    runtimeClient: existing,
                    reusedExistingClient: true,
                    replacedDueToWorkingDirectoryChange: false,
                    previousWorkingDirectory: runtimeWorkingDirectories[session.sessionId]
                )
            }

            let previousWorkingDirectory = runtimeWorkingDirectories[session.sessionId]
            debugLog(
                "runtimeClient replace localSession=\(session.sessionId) oldWorkingDirectory=\(previousWorkingDirectory ?? "nil") newWorkingDirectory=\(workingDirectory)"
            )
            await existing.close()
            runtimeClients.removeValue(forKey: session.sessionId)
            runtimeWorkingDirectories.removeValue(forKey: session.sessionId)
            sessionRuntimeResetter(session.sessionId)

            let client = try await buildRuntimeClient(
                configuration: configuration,
                session: session,
                workingDirectory: workingDirectory,
                authorizationPolicy: authorizationPolicy,
                permissionResolver: makePermissionResolver(localSessionID: session.sessionId),
                updateSink: makeUpdateSink(localSessionID: session.sessionId)
            )
            runtimeClients[session.sessionId] = client
            runtimeWorkingDirectories[session.sessionId] = workingDirectory
            debugLog(
                "runtimeClient created localSession=\(session.sessionId) workingDirectory=\(workingDirectory)"
            )
            return RuntimeClientAcquisition(
                runtimeClient: client,
                reusedExistingClient: false,
                replacedDueToWorkingDirectoryChange: true,
                previousWorkingDirectory: previousWorkingDirectory
            )
        }

        let client = try await buildRuntimeClient(
            configuration: configuration,
            session: session,
            workingDirectory: workingDirectory,
            authorizationPolicy: authorizationPolicy,
            permissionResolver: makePermissionResolver(localSessionID: session.sessionId),
            updateSink: makeUpdateSink(localSessionID: session.sessionId)
        )
        runtimeClients[session.sessionId] = client
        runtimeWorkingDirectories[session.sessionId] = workingDirectory
        debugLog(
            "runtimeClient created localSession=\(session.sessionId) workingDirectory=\(workingDirectory)"
        )
        return RuntimeClientAcquisition(
            runtimeClient: client,
            reusedExistingClient: false,
            replacedDueToWorkingDirectoryChange: false,
            previousWorkingDirectory: nil
        )
    }

    private func makePermissionResolver(
        localSessionID: String
    ) -> @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse? {
        let permissionCenter = permissionCenter
        let source = ACPPermissionCenter.RequestSource(providerID: id, localSessionID: localSessionID)

        return { [self] request, policy in
            let response = await permissionCenter.resolve(request: request, source: source, policy: policy)
            await MainActor.run {
                self.applyPermissionResolution(response, request: request, localSessionID: localSessionID)
            }
            return response
        }
    }

    private func makeUpdateSink(localSessionID: String) -> @Sendable (CopilotACPUpdate) async -> Void {
        { [weak self] update in
            guard let self else { return }
            let task = await self.enqueueUpdateTask(update: update, localSessionID: localSessionID)
            await task.value
        }
    }

    @MainActor
    private func enqueueUpdateTask(update: CopilotACPUpdate, localSessionID: String) -> Task<Void, Never> {
        let previousTask = pendingUpdateTasks[localSessionID]
        let token = UUID()
        let task = Task { [weak self] in
            await previousTask?.value
            await self?.consumeOnMain(update: update, localSessionID: localSessionID)
            await self?.finishUpdateTask(localSessionID: localSessionID, token: token)
        }
        pendingUpdateTasks[localSessionID] = task
        pendingUpdateTaskTokens[localSessionID] = token
        return task
    }

    @MainActor
    private func finishUpdateTask(localSessionID: String, token: UUID) {
        guard pendingUpdateTaskTokens[localSessionID] == token else { return }
        pendingUpdateTasks.removeValue(forKey: localSessionID)
        pendingUpdateTaskTokens.removeValue(forKey: localSessionID)
    }

    @MainActor
    private func drainPendingUpdates(localSessionID: String) async {
        for _ in 0..<3 {
            while let task = pendingUpdateTasks[localSessionID] {
                await task.value
            }
            await Task.yield()
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
        if let discoveredRemoteSessionID = discoveredRemoteSessionID(for: update) {
            remoteSessionIDs[localSessionID] = discoveredRemoteSessionID
        }

        if let modelContext = sessionContexts[localSessionID],
           let remoteSessionID = remoteSessionID(for: update, localSessionID: localSessionID) {
            let featureEvents = featureExtractor.extract(
                update: update,
                providerID: id,
                remoteSessionID: remoteSessionID
            )
            if !featureEvents.isEmpty {
                debugLog(
                    "consume featureEvents localSession=\(localSessionID) remoteSession=\(remoteSessionID) count=\(featureEvents.count) updates=\(describeFeatureEvents(featureEvents))"
                )
            }
            try? applyFeatureEvents(featureEvents, localSessionID: localSessionID, modelContext: modelContext)
        } else {
            debugLog(
                "consume missing feature context localSession=\(localSessionID) updateKind=\(describeUpdate(update)) hasModelContext=\(sessionContexts[localSessionID] != nil) remoteSession=\(remoteSessionIDs[localSessionID] ?? "nil")"
            )
        }

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
              let remoteSessionID = trimmedNonEmpty(storedBinding.remoteSessionID) else {
            return nil
        }

        let bridgeBinding = CopilotSessionBridge.Binding(
            sessionID: localSessionID,
            providerID: id,
            remoteSessionID: remoteSessionID,
            cliVersion: trimmedNonEmpty(storedBinding.agentVersion),
            negotiatedCapabilities: storedBinding.negotiatedCapabilities,
            lastHandshakeAt: storedBinding.lastHandshakeAt,
            lastSelectedModel: trimmedNonEmpty(storedBinding.lastSelectedModel),
            lastSelectedAgentName: trimmedNonEmpty(storedBinding.lastSelectedAgentName)
        )
        await sessionBridge.upsert(bridgeBinding)
        return bridgeBinding
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
            debugLog(
                "runtimeClient closing inactive localSession=\(inactiveSessionID) keeping=\(localSessionID)"
            )
            permissionCenter.cancelRequests(for: inactiveSessionID)
            if let runtimeClient = runtimeClients.removeValue(forKey: inactiveSessionID) {
                await runtimeClient.close()
            }
            runtimeWorkingDirectories.removeValue(forKey: inactiveSessionID)
            remoteSessionIDs.removeValue(forKey: inactiveSessionID)
            sessionRuntimeResetter(inactiveSessionID)
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
            remoteSessionIDs.removeValue(forKey: activeSessionID)
            sessionRuntimeResetter(activeSessionID)
            markCancelledIfNeeded(sessionID: activeSessionID)
        }
    }

    private func resetRuntime(
        for localSessionID: String,
        modelContext: ModelContext,
        removeBinding: Bool = true
    ) async {
        debugLog(
            "runtimeClient reset localSession=\(localSessionID) removeBinding=\(removeBinding)"
        )
        permissionCenter.cancelRequests(for: localSessionID)
        turnRouter.reset(sessionID: localSessionID)
        if let runtimeClient = runtimeClients.removeValue(forKey: localSessionID) {
            await runtimeClient.close()
        }
        runtimeWorkingDirectories.removeValue(forKey: localSessionID)
        remoteSessionIDs.removeValue(forKey: localSessionID)
        sessionContexts.removeValue(forKey: localSessionID)
        sessionRuntimeResetter(localSessionID)
        if removeBinding {
            await sessionBridge.removeBinding(for: localSessionID, providerID: id)
            try? bindingStore(in: modelContext).removeBinding(for: localSessionID, providerID: id)
        }
        activeTurns.removeValue(forKey: localSessionID)
        featureStores.removeValue(forKey: localSessionID)
        pendingUpdateTasks.removeValue(forKey: localSessionID)
        pendingUpdateTaskTokens.removeValue(forKey: localSessionID)
    }

    private struct RemoteSessionActivation {
        let remoteBinding: CopilotSessionBridge.Binding?
        let runtimeClient: any ACPExternalProviderRuntimeClient
        let handshake: ACPExternalAgentSessionHandshake
    }

    private struct RuntimeClientAcquisition {
        let runtimeClient: any ACPExternalProviderRuntimeClient
        let reusedExistingClient: Bool
        let replacedDueToWorkingDirectoryChange: Bool
        let previousWorkingDirectory: String?
    }

    private func ensureRemoteSessionPrepared(
        session: Session,
        configuration: Configuration,
        settings: AppSettings,
        modelContext: ModelContext,
        authorizationPolicy: ToolAuthorizationPolicy,
        workingDirectoryOverride: String?
    ) async throws -> RemoteSessionActivation {
        sessionContexts[session.sessionId] = modelContext
        let remoteBinding = await resolvedBinding(
            for: session.sessionId,
            modelContext: modelContext
        )
        let workingDirectory = resolvedWorkingDirectory(
            session: session,
            settings: settings,
            override: workingDirectoryOverride
        )
        debugLog(
            "ensureRemoteSessionPrepared start localSession=\(session.sessionId) existingRemote=\(trimmedNonEmpty(remoteBinding?.remoteSessionID) ?? "nil") workingDirectory=\(workingDirectory)"
        )

        let acquisition = try await makeRuntimeClientIfNeeded(
            session: session,
            configuration: configuration,
            workingDirectory: workingDirectory,
            authorizationPolicy: authorizationPolicy
        )
        debugLog(
            "ensureRemoteSessionPrepared runtime ready localSession=\(session.sessionId) reusedClient=\(acquisition.reusedExistingClient) replacedForWorkingDirectory=\(acquisition.replacedDueToWorkingDirectoryChange) previousWorkingDirectory=\(acquisition.previousWorkingDirectory ?? "nil") activeWorkingDirectory=\(workingDirectory)"
        )
        var runtimeClient = acquisition.runtimeClient

        debugLog(
            "ensureRemoteSessionPrepared begin restore gate localSession=\(session.sessionId) requestedRemote=\(trimmedNonEmpty(remoteBinding?.remoteSessionID) ?? "nil")"
        )
        turnRouter.beginRestore(sessionID: session.sessionId)
        defer { turnRouter.finishRestore(sessionID: session.sessionId) }

        debugLog(
            "ensureRemoteSessionPrepared calling ensureSession localSession=\(session.sessionId) requestedRemote=\(trimmedNonEmpty(remoteBinding?.remoteSessionID) ?? "nil")"
        )
        let requestedRemoteSessionID = trimmedNonEmpty(remoteBinding?.remoteSessionID)
        let handshake: ACPExternalAgentSessionHandshake
        do {
            handshake = try await runtimeClient.ensureSession(
                workingDirectory: workingDirectory,
                remoteSessionID: requestedRemoteSessionID
            )
        } catch ACPExternalAgentRuntimeError.initializeTimedOut {
            debugLog(
                "ensureRemoteSessionPrepared initialize timed out localSession=\(session.sessionId); rebuilding runtime and retrying"
            )
            if let existingRuntimeClient = runtimeClients.removeValue(forKey: session.sessionId) {
                await existingRuntimeClient.close()
            }
            runtimeWorkingDirectories.removeValue(forKey: session.sessionId)
            sessionRuntimeResetter(session.sessionId)

            let retryAcquisition = try await makeRuntimeClientIfNeeded(
                session: session,
                configuration: configuration,
                workingDirectory: workingDirectory,
                authorizationPolicy: authorizationPolicy
            )
            debugLog(
                "ensureRemoteSessionPrepared retry runtime ready localSession=\(session.sessionId) reusedClient=\(retryAcquisition.reusedExistingClient) replacedForWorkingDirectory=\(retryAcquisition.replacedDueToWorkingDirectoryChange) previousWorkingDirectory=\(retryAcquisition.previousWorkingDirectory ?? "nil") activeWorkingDirectory=\(workingDirectory)"
            )
            runtimeClient = retryAcquisition.runtimeClient
            handshake = try await runtimeClient.ensureSession(
                workingDirectory: workingDirectory,
                remoteSessionID: requestedRemoteSessionID
            )
        }
        debugLog(
            "ensureRemoteSessionPrepared ensured session localSession=\(session.sessionId) remoteSession=\(handshake.remoteSessionID)"
        )

        await persistBinding(
            sessionID: session.sessionId,
            remoteSessionID: handshake.remoteSessionID,
            configuration: configuration,
            handshake: handshake,
            selectedModel: nil,
            modelContext: modelContext
        )
        remoteSessionIDs[session.sessionId] = handshake.remoteSessionID

        try applyFeatureEvents(
            featureAdapter.bootstrapEvents(
                providerID: id,
                remoteSessionID: handshake.remoteSessionID
            ),
            localSessionID: session.sessionId,
            modelContext: modelContext
        )
        debugLog(
            "ensureRemoteSessionPrepared bootstrap applied localSession=\(session.sessionId) remoteSession=\(handshake.remoteSessionID) cachedCommands=\(remoteCommands(localSessionID: session.sessionId, remoteSessionID: handshake.remoteSessionID).count)"
        )

        return RemoteSessionActivation(
            remoteBinding: remoteBinding,
            runtimeClient: runtimeClient,
            handshake: handshake
        )
    }

    private func bindingStore(in modelContext: ModelContext) -> ACPExternalSessionBindingStore {
        ACPExternalSessionBindingStore(modelContext: modelContext)
    }

    func remoteCommands(localSessionID: String, remoteSessionID: String) -> [ACPCommandDescriptor] {
        featureStores[localSessionID]?.commands(for: id, remoteSessionID: remoteSessionID) ?? []
    }

    func remoteCommands(localSessionID: String) -> [ACPCommandDescriptor] {
        if let cached = featureStores[localSessionID]?.commands(for: localSessionID, providerID: id),
           !cached.isEmpty {
            debugLog(
                "remoteCommands hit session cache localSession=\(localSessionID) count=\(cached.count) names=\(cached.map(\.name).joined(separator: ","))"
            )
            return cached
        }

        guard let remoteSessionID = remoteSessionIDs[localSessionID] else {
            debugLog("remoteCommands miss localSession=\(localSessionID) reason=no-remote-session")
            return []
        }
        let commands = remoteCommands(localSessionID: localSessionID, remoteSessionID: remoteSessionID)
        debugLog(
            "remoteCommands resolved via remote cache localSession=\(localSessionID) remoteSession=\(remoteSessionID) count=\(commands.count) names=\(commands.map(\.name).joined(separator: ","))"
        )
        return commands
    }

    func remotePlan(localSessionID: String) -> ACPPlanSnapshotDraft? {
        featureStores[localSessionID]?.plan(for: localSessionID)
    }

    private func applyFeatureEvents(
        _ events: [ACPExternalSessionFeatureEvent],
        localSessionID: String,
        modelContext: ModelContext
    ) throws {
        guard !events.isEmpty else { return }
        let store = featureStore(for: localSessionID, modelContext: modelContext)
        try store.apply(events, sessionID: localSessionID)
    }

    private func featureStore(for localSessionID: String, modelContext: ModelContext) -> ACPExternalSessionFeatureStore {
        if let existing = featureStores[localSessionID] {
            return existing
        }

        let store = ACPExternalSessionFeatureStore(
            taskStateStore: SessionTaskStateStore(modelContext: modelContext),
            planProjector: ACPPlanProjector()
        )
        featureStores[localSessionID] = store
        return store
    }

    private func remoteSessionID(for update: CopilotACPUpdate, localSessionID: String) -> String? {
        switch update {
        case .session:
            return remoteSessionIDs[localSessionID]
        case .sessionNotification(let notification):
            return trimmedNonEmpty(notification.sessionID) ?? remoteSessionIDs[localSessionID]
        case .permission(let request):
            return trimmedNonEmpty(request.sessionID) ?? remoteSessionIDs[localSessionID]
        }
    }

    private func discoveredRemoteSessionID(for update: CopilotACPUpdate) -> String? {
        switch update {
        case .session:
            return nil
        case .sessionNotification(let notification):
            return trimmedNonEmpty(notification.sessionID)
        case .permission(let request):
            return trimmedNonEmpty(request.sessionID)
        }
    }

    private func describeUpdate(_ update: CopilotACPUpdate) -> String {
        switch update {
        case .session(let update):
            switch update {
            case .userMessageChunk:
                return "userMessageChunk"
            case .agentMessageChunk:
                return "agentMessageChunk"
            case .agentThoughtChunk:
                return "agentThoughtChunk"
            case .toolCall:
                return "toolCall"
            case .toolCallUpdate:
                return "toolCallUpdate"
            case .plan:
                return "plan"
            case .availableCommandsUpdate:
                return "availableCommandsUpdate"
            case .other(let kind, _):
                return "other[\(kind)]"
            }
        case .sessionNotification(let notification):
            switch notification.update {
            case .userMessageChunk:
                return "userMessageChunk"
            case .agentMessageChunk:
                return "agentMessageChunk"
            case .agentThoughtChunk:
                return "agentThoughtChunk"
            case .toolCall:
                return "toolCall"
            case .toolCallUpdate:
                return "toolCallUpdate"
            case .plan:
                return "plan"
            case .availableCommandsUpdate:
                return "availableCommandsUpdate"
            case .other(let kind, _):
                return "other[\(kind)]"
            }
        case .permission:
            return "permission"
        }
    }

    private func describeFeatureEvents(_ events: [ACPExternalSessionFeatureEvent]) -> String {
        events.map { event in
            switch event {
            case .replaceCommands(let snapshot):
                let names = snapshot.commands.map(\.name).joined(separator: ",")
                return "replaceCommands[count=\(snapshot.commands.count) names=\(names)]"
            case .replacePlan(let snapshot):
                return "replacePlan[entries=\(snapshot.entries.count)]"
            }
        }.joined(separator: ";")
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

func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
