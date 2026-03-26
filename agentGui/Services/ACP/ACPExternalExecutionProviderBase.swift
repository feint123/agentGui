import Foundation
import SwiftData

typealias ACPExternalTerminalRuntimeFactory = @Sendable (String, String?) async -> TerminalTaskRuntime
typealias ACPExternalSessionRuntimeResetter = @Sendable (String) async -> Void

@MainActor
class ACPExternalExecutionProviderBase<Configuration>: ConversationExecutionProvider, ACPRemoteSessionConfigurationControlling {
    let id: ConversationExecutionProviderID
    let runtimeScope: ConversationExecutionRuntimeScope? = .externalACP

    nonisolated private let terminalRuntimeFactory: ACPExternalTerminalRuntimeFactory
    nonisolated private let sessionRuntimeResetter: ACPExternalSessionRuntimeResetter
    private let permissionCenter: ACPPermissionCenter
    private let authorizationPolicyFactory: ConversationAuthorizationPolicyFactory
    private let runtimeSupervisor: ACPProviderRuntimeSupervisor
    private let normalizer = CopilotACPEventNormalizer()
    private let featureExtractor = ACPExternalSessionFeatureExtractor()
    private let updateProjector = ACPExternalUpdateProjector()
    private let turnRouter = ACPExternalSessionTurnRouter()
    private let updateRouter = ACPSessionUpdateRouter()
    private let featureAdapter: ACPExternalProviderFeatureAdapter
    private let sessionStateStore = ACPExternalProviderSessionStateStore()
    private let updateQueue = ACPExternalProviderUpdateQueue()

    private struct StoredRemoteBinding {
        let remoteSessionID: String
        let agentVersion: String?
        let negotiatedCapabilities: ACPExternalAgentCapabilitySnapshot?
        let lastHandshakeAt: Date?
        let lastSelectedModel: String?
        let lastSelectedAgentName: String?
    }

    init(
        providerID: ConversationExecutionProviderID,
        terminalRuntimeFactory: @escaping ACPExternalTerminalRuntimeFactory,
        sessionRuntimeResetter: @escaping ACPExternalSessionRuntimeResetter,
        permissionCenter: ACPPermissionCenter,
        authorizationPolicyFactory: ConversationAuthorizationPolicyFactory,
        featureAdapter: ACPExternalProviderFeatureAdapter = ACPExternalProviderFeatureAdapter()
    ) {
        self.id = providerID
        self.terminalRuntimeFactory = terminalRuntimeFactory
        self.sessionRuntimeResetter = sessionRuntimeResetter
        self.permissionCenter = permissionCenter
        self.authorizationPolicyFactory = authorizationPolicyFactory
        self.runtimeSupervisor = ACPProviderRuntimeSupervisor(providerID: providerID)
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

            if let preferredModeID = initialSessionModeID(for: request.session, handshake: handshake),
               preferredModeID != handshake.configurationSnapshot.modes?.currentModeID {
                try await runtimeClient.setSessionMode(preferredModeID, sessionID: handshake.remoteSessionID)
                try applyFeatureEvents(
                    [
                        .updateCurrentMode(
                            providerID: id,
                            remoteSessionID: handshake.remoteSessionID,
                            currentModeID: preferredModeID
                        )
                    ],
                    localSessionID: request.session.sessionId,
                    modelContext: request.modelContext
                )
            }

            let initialConfigSelections = initialSessionConfigSelections(for: configuration, handshake: handshake)
            var selectedModel: String?
            var latestConfigOptions: [ACPSessionConfigOption]?
            for selection in initialConfigSelections {
                let updatedConfigOptions = try await runtimeClient.setSessionConfigOption(
                    selection.configID,
                    value: selection.value,
                    sessionID: handshake.remoteSessionID
                )
                if updatedConfigOptions.isEmpty == false {
                    latestConfigOptions = updatedConfigOptions
                }
                if case .some(ACPSessionConfigOptionCategory.model) = selection.category {
                    selectedModel = updatedConfigOptions.first(where: {
                        $0.id?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) == selection.configID
                    })?.currentValue ?? selection.value
                }
            }

            let projectedConfigOptions = resolvedProjectedConfigOptions(
                explicitOptions: latestConfigOptions,
                localSessionID: request.session.sessionId,
                remoteSessionID: handshake.remoteSessionID,
                handshakeConfigOptions: handshake.configurationSnapshot.configOptions,
                selections: initialConfigSelections
            )
            if let projectedConfigOptions, projectedConfigOptions.isEmpty == false {
                try applyFeatureEvents(
                    [
                        .replaceSessionConfiguration(
                            ACPExternalSessionConfigurationDraft(
                                providerID: id,
                                remoteSessionID: handshake.remoteSessionID,
                                configOptions: projectedConfigOptions,
                                modes: nil
                            )
                        )
                    ],
                    localSessionID: request.session.sessionId,
                    modelContext: request.modelContext
                )
            }

            await persistBinding(
                sessionID: request.session.sessionId,
                remoteSessionID: handshake.remoteSessionID,
                configuration: configuration,
                handshake: handshake,
                selectedModel: selectedModel,
                modelContext: request.modelContext
            )

            let promptText = makePromptText(
                currentText: request.text,
                session: request.session,
                remoteSessionID: remoteBinding?.remoteSessionID
            )
            let assistantMessage = resolveAssistantMessage(for: request)
            updateProjector.reset(sessionID: request.session.sessionId)
            let sessionState = sessionStateStore.state(for: request.session.sessionId)
            sessionState.resetProjectedMutations()
            sessionState.activeTurn = ACPExternalProviderActiveTurnState(
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
            sessionState.resetProjectedMutations()
            sessionState.activeTurn = nil
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

        if let remoteSessionID = sessionStateStore.existingState(for: session.sessionId)?.remoteSessionID
            ?? storedRemoteSessionID(for: session.sessionId, modelContext: modelContext),
           let runtimeActor = await runtimeSupervisor.existingActivation(for: session.sessionId) {
            try? await runtimeActor.cancel(sessionID: remoteSessionID)
        }

        let sessionState = sessionStateStore.state(for: session.sessionId)
        if let activeTurn = sessionState.activeTurn {
            flushProjectedUpdates(for: session.sessionId)
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
            sessionState.resetProjectedMutations()
            sessionState.activeTurn = nil
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
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger
    ) async {
        debugLog(
            "prepareForActivation start localSession=\(session.sessionId) isActive=\(isActiveProvider) trigger=\(String(describing: trigger))"
        )
        guard isActiveProvider else {
            debugLog("prepareForActivation skipped because provider is inactive localSession=\(session.sessionId)")
            return
        }

        guard trigger == .selection || trigger == .sessionBootstrap || trigger == .executionDispatch else {
            debugLog(
                "prepareForActivation finished without remote warmup localSession=\(session.sessionId)"
            )
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

    func releasePreparedRuntime(
        localSessionID: String,
        modelContext: ModelContext,
        reason: ConversationExecutionRuntimeReleaseReason
    ) async {
        debugLog(
            "releasePreparedRuntime localSession=\(localSessionID) reason=\(String(describing: reason))"
        )
        await resetRuntime(
            for: localSessionID,
            modelContext: modelContext,
            removeBinding: false
        )
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

    nonisolated func buildRuntimeClient(
        configuration: Configuration,
        localSessionID: String,
        workingDirectory: String,
        authorizationPolicy: ToolAuthorizationPolicy,
        permissionResolver: @escaping @Sendable (ACPRequestPermissionRequest, ToolAuthorizationPolicy) async -> ACPRequestPermissionResponse?,
        updateSink: @escaping @Sendable (CopilotACPUpdate) async -> Void
    ) async throws -> any ACPExternalProviderRuntimeTransportClient {
        fatalError("Subclasses must override buildRuntimeClient")
    }

    func initialSessionConfigSelections(
        for configuration: Configuration,
        handshake: ACPExternalAgentSessionHandshake
    ) -> [ACPExternalSessionConfigSelection] {
        fatalError("Subclasses must override initialSessionConfigSelections")
    }

    func initialSessionModeID(
        for session: Session,
        handshake: ACPExternalAgentSessionHandshake
    ) -> String? {
        _ = session
        _ = handshake
        return nil
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

    nonisolated func makeTerminalRuntime(sessionID: String, workingDirectory: String) async -> TerminalTaskRuntime {
        await terminalRuntimeFactory(sessionID, workingDirectory)
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

    private func makeUpdateSink(
        localSessionID: String,
        activationID: RuntimeActivationID
    ) -> @Sendable (CopilotACPUpdate) async -> Void {
        { [weak self] update in
            guard let self else { return }
            await self.updateQueue.enqueue(localSessionID: localSessionID) { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.consume(
                        update: update,
                        localSessionID: localSessionID,
                        activationID: activationID
                    )
                }
            }
        }
    }

    private func drainPendingUpdates(localSessionID: String) async {
        await updateQueue.drain(localSessionID: localSessionID)
    }

    private func recordProjectedMutation(
        localSessionID: String,
        count: Int = 1
    ) {
        guard let sessionState = sessionStateStore.existingState(for: localSessionID) else {
            return
        }

        guard sessionState.recordProjectedMutation(count: count) else {
            return
        }

        persistProjectedMutationsIfNeeded(localSessionID: localSessionID)
    }

    private func persistProjectedMutationsIfNeeded(localSessionID: String) {
        guard let sessionState = sessionStateStore.existingState(for: localSessionID),
              sessionState.hasPendingProjectedMutations,
              let activeTurn = sessionState.activeTurn else {
            return
        }

        try? activeTurn.modelContext.save()
        sessionState.resetProjectedMutations()
    }

    private func applyPermissionResolution(
        _ response: ACPRequestPermissionResponse?,
        request: ACPRequestPermissionRequest,
        localSessionID: String
    ) {
        guard let response,
              let activeTurn = sessionStateStore.existingState(for: localSessionID)?.activeTurn else {
            return
        }

        let kind = ToolKind.classify(rawName: request.toolCall.kind?.rawValue)
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
            toolCall.status = ToolStatus.cancelled
            toolCall.toolResultSummary = "权限请求已取消"
            toolCall.endTime = toolCall.endTime ?? Date()
        case .selected(let outcome):
            guard let option = request.options.first(where: { $0.optionID == outcome.optionID }) else {
                break
            }
            switch option.kind {
            case .rejectOnce, .rejectAlways:
                toolCall.status = ToolStatus.cancelled
                toolCall.toolResultSummary = "权限被拒绝"
                toolCall.endTime = toolCall.endTime ?? Date()
            case .allowOnce, .allowAlways:
                toolCall.status = ToolStatus.success
                toolCall.toolResultSummary = "权限已批准"
                toolCall.endTime = toolCall.endTime ?? Date()
            }
        case .other:
            break
        }

        recordProjectedMutation(localSessionID: localSessionID)
    }

    private func consume(
        update: CopilotACPUpdate,
        localSessionID: String,
        activationID: RuntimeActivationID
    ) {
        guard let sessionState = sessionStateStore.existingState(for: localSessionID) else {
            return
        }

        if sessionState.activationID == nil,
           turnRouter.runtimePhase(for: localSessionID) == .restoring {
            sessionState.activationID = activationID
            debugLog(
                "consume seeded activation during restore localSession=\(localSessionID) activationID=\(activationID.rawValue.uuidString)"
            )
        }

        guard let currentActivationID = sessionState.activationID else {
            return
        }

        let phase = turnRouter.runtimePhase(for: localSessionID)

        guard updateRouter.shouldConsumeFeatureUpdate(
            updateActivationID: activationID,
            currentActivationID: currentActivationID,
            phase: phase
        ) else {
            return
        }

        if let discoveredRemoteSessionID = discoveredRemoteSessionID(for: update) {
            sessionState.remoteSessionID = discoveredRemoteSessionID
        }

        if let modelContext = sessionState.modelContext,
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
                "consume missing feature context localSession=\(localSessionID) updateKind=\(describeUpdate(update)) hasModelContext=\(sessionState.modelContext != nil) remoteSession=\(sessionState.remoteSessionID ?? "nil")"
            )
        }

        guard updateRouter.shouldProject(
            updateActivationID: activationID,
            currentActivationID: currentActivationID,
            phase: phase
        ) else {
            return
        }

        guard let activeTurn = sessionState.activeTurn else {
            return
        }

        let projectedEvents = updateProjector.project(
            events: normalizer.normalize(update: update),
            sessionID: localSessionID
        )

        for event in projectedEvents {
            apply(event: event, to: activeTurn.assistantMessage, in: activeTurn.modelContext)
        }

        if projectedEvents.isEmpty == false {
            recordProjectedMutation(localSessionID: localSessionID, count: projectedEvents.count)
        }
    }

    private func flushProjectedUpdates(for sessionID: String) {
        guard let activeTurn = sessionStateStore.existingState(for: sessionID)?.activeTurn else {
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

        recordProjectedMutation(localSessionID: sessionID, count: pendingEvents.count)
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
        let sessionState = sessionStateStore.state(for: sessionID)
        if let activeTurn = sessionState.activeTurn {
            sessionState.activeTurn = nil
            activeTurn.assistantMessage.status = .failed
            activeTurn.assistantMessage.errorMessage = error.localizedDescription
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .failed)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "错误: \(error.localizedDescription)"
            }
            try? activeTurn.modelContext.save()
            sessionState.resetProjectedMutations()
        } else {
            _ = modelContext
        }
    }

    private func resolvedBinding(
        for localSessionID: String,
        modelContext: ModelContext
    ) async -> StoredRemoteBinding? {
        guard let storedBinding = try? bindingStore(in: modelContext).binding(for: localSessionID, providerID: id),
              let remoteSessionID = trimmedNonEmpty(storedBinding.remoteSessionID) else {
            return nil
        }

        let binding = StoredRemoteBinding(
            remoteSessionID: remoteSessionID,
            agentVersion: trimmedNonEmpty(storedBinding.agentVersion),
            negotiatedCapabilities: storedBinding.negotiatedCapabilities,
            lastHandshakeAt: storedBinding.lastHandshakeAt,
            lastSelectedModel: trimmedNonEmpty(storedBinding.lastSelectedModel),
            lastSelectedAgentName: trimmedNonEmpty(storedBinding.lastSelectedAgentName)
        )
        sessionStateStore.state(for: localSessionID).remoteSessionID = remoteSessionID
        return binding
    }

    private func storedRemoteSessionID(for localSessionID: String, modelContext: ModelContext) -> String? {
        guard let storedBinding = try? bindingStore(in: modelContext).binding(for: localSessionID, providerID: id) else {
            return nil
        }
        return trimmedNonEmpty(storedBinding.remoteSessionID)
    }

    private func markCancelledIfNeeded(sessionID: String) {
        let sessionState = sessionStateStore.state(for: sessionID)
        if let activeTurn = sessionState.activeTurn {
            sessionState.activeTurn = nil
            activeTurn.assistantMessage.status = .cancelled
            settleOutstandingToolCalls(in: activeTurn.assistantMessage, terminalStatus: .cancelled)
            if activeTurn.assistantMessage.textContent?.isEmpty ?? true {
                activeTurn.assistantMessage.textContent = "(已取消)"
            }
            try? activeTurn.modelContext.save()
            sessionState.resetProjectedMutations()
        }
    }

    private func closeInactiveSessionRuntimes(keeping localSessionID: String) async {
        let inactiveSessionIDs = (await runtimeSupervisor.activeLocalSessionIDs()).filter { $0 != localSessionID }
        for inactiveSessionID in inactiveSessionIDs {
            debugLog(
                "runtimeClient closing inactive localSession=\(inactiveSessionID) keeping=\(localSessionID)"
            )
            permissionCenter.cancelRequests(for: inactiveSessionID)
            markCancelledIfNeeded(sessionID: inactiveSessionID)
            await runtimeSupervisor.removeActivation(for: inactiveSessionID)
            await updateQueue.clear(localSessionID: inactiveSessionID)
            sessionStateStore.state(for: inactiveSessionID).clearRuntimeState(
                removeBinding: false,
                removeFeatureStore: false
            )
            await sessionRuntimeResetter(inactiveSessionID)
        }
    }

    private func deactivateAllSessionRuntimes() async {
        let activeSessionIDs = await runtimeSupervisor.activeLocalSessionIDs()
        for activeSessionID in activeSessionIDs {
            permissionCenter.cancelRequests(for: activeSessionID)
            markCancelledIfNeeded(sessionID: activeSessionID)
            await runtimeSupervisor.removeActivation(for: activeSessionID)
            await updateQueue.clear(localSessionID: activeSessionID)
            sessionStateStore.state(for: activeSessionID).clearRuntimeState(
                removeBinding: false,
                removeFeatureStore: false
            )
            await sessionRuntimeResetter(activeSessionID)
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
        await runtimeSupervisor.removeActivation(for: localSessionID)
        await updateQueue.clear(localSessionID: localSessionID)
        await sessionRuntimeResetter(localSessionID)
        if removeBinding {
            try? bindingStore(in: modelContext).removeBinding(for: localSessionID, providerID: id)
        }
        if removeBinding {
            sessionStateStore.removeState(for: localSessionID)
        } else {
            sessionStateStore.state(for: localSessionID).clearRuntimeState(
                removeBinding: false,
                removeFeatureStore: true
            )
        }
    }

    private struct RemoteSessionActivation {
        let remoteBinding: StoredRemoteBinding?
        let runtimeClient: any ACPExternalProviderRuntimeTransportClient
        let handshake: ACPExternalAgentSessionHandshake
    }

    private func ensureRemoteSessionPrepared(
        session: Session,
        configuration: Configuration,
        settings: AppSettings,
        modelContext: ModelContext,
        authorizationPolicy: ToolAuthorizationPolicy,
        workingDirectoryOverride: String?
    ) async throws -> RemoteSessionActivation {
        sessionStateStore.state(for: session.sessionId).modelContext = modelContext
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

        return try await ensureRemoteSessionPreparedViaActor(
            session: session,
            configuration: configuration,
            modelContext: modelContext,
            authorizationPolicy: authorizationPolicy,
            remoteBinding: remoteBinding,
            workingDirectory: workingDirectory
        )
    }

    private func ensureRemoteSessionPreparedViaActor(
        session: Session,
        configuration: Configuration,
        modelContext: ModelContext,
        authorizationPolicy: ToolAuthorizationPolicy,
        remoteBinding: StoredRemoteBinding?,
        workingDirectory: String
    ) async throws -> RemoteSessionActivation {
        let createdRuntimeActor = makeSessionRuntimeActor(
            session: session,
            configuration: configuration,
            modelContext: modelContext,
            authorizationPolicy: authorizationPolicy
        )
        let runtimeActor = await runtimeSupervisor.activation(for: session.sessionId) { createdRuntimeActor }

        debugLog(
            "ensureRemoteSessionPrepared runtime actor ready localSession=\(session.sessionId) activationID=\((await runtimeActor.activationID).rawValue.uuidString) workingDirectory=\(workingDirectory)"
        )

        debugLog(
            "ensureRemoteSessionPrepared begin restore gate localSession=\(session.sessionId) requestedRemote=\(trimmedNonEmpty(remoteBinding?.remoteSessionID) ?? "nil")"
        )
        turnRouter.beginRestore(sessionID: session.sessionId)
        defer { turnRouter.finishRestore(sessionID: session.sessionId) }

        let prepared: ACPSessionRuntimeActor.PreparedRuntimeSession
        prepared = try await runtimeActor.prepareRuntimeSession(workingDirectory: workingDirectory)

        let activationID = await runtimeActor.activationID
        let sessionState = sessionStateStore.state(for: session.sessionId)
        let previousActivationID = sessionState.activationID
        sessionState.activationID = activationID
        sessionState.remoteSessionID = prepared.handshake.remoteSessionID

        let existingConfiguration = sessionState.sessionConfiguration(
            for: id,
            remoteSessionID: prepared.handshake.remoteSessionID
        )

        debugLog(
            "ensureRemoteSessionPrepared actor ensured session localSession=\(session.sessionId) activationID=\(activationID.rawValue.uuidString) remoteSession=\(prepared.handshake.remoteSessionID)"
        )

        try applyFeatureEvents(
            bootstrapFeatureEvents(
                handshake: prepared.handshake,
                previousActivationID: previousActivationID,
                currentActivationID: activationID,
                hasExistingConfiguration: existingConfiguration != nil
            ) + featureAdapter.bootstrapEvents(
                providerID: id,
                remoteSessionID: prepared.handshake.remoteSessionID
            ),
            localSessionID: session.sessionId,
            modelContext: modelContext
        )
        debugLog(
            "ensureRemoteSessionPrepared bootstrap applied localSession=\(session.sessionId) remoteSession=\(prepared.handshake.remoteSessionID) cachedCommands=\(remoteCommands(localSessionID: session.sessionId, remoteSessionID: prepared.handshake.remoteSessionID).count)"
        )

        return RemoteSessionActivation(
            remoteBinding: remoteBinding,
            runtimeClient: prepared.runtimeClient,
            handshake: prepared.handshake
        )
    }

    private func bootstrapFeatureEvents(
        handshake: ACPExternalAgentSessionHandshake,
        previousActivationID: RuntimeActivationID?,
        currentActivationID: RuntimeActivationID,
        hasExistingConfiguration: Bool
    ) -> [ACPExternalSessionFeatureEvent] {
        let isSameHotActivation = previousActivationID == currentActivationID
        guard hasExistingConfiguration == false || isSameHotActivation == false else {
            return []
        }

        return featureExtractor.bootstrapEvents(
            configurationSnapshot: handshake.configurationSnapshot,
            providerID: id,
            remoteSessionID: handshake.remoteSessionID
        )
    }

    private func makeSessionRuntimeActor(
        session: Session,
        configuration: Configuration,
        modelContext: ModelContext,
        authorizationPolicy: ToolAuthorizationPolicy
    ) -> ACPSessionRuntimeActor {
        let key = SessionRuntimeKey(providerID: id, localSessionID: session.sessionId)

        return ACPSessionRuntimeActor(
            key: key,
            runtimeFactory: { workingDirectory, activationID in
                try await self.buildRuntimeClient(
                    configuration: configuration,
                    localSessionID: session.sessionId,
                    workingDirectory: workingDirectory,
                    authorizationPolicy: authorizationPolicy,
                    permissionResolver: self.makePermissionResolver(localSessionID: session.sessionId),
                    updateSink: self.makeUpdateSink(localSessionID: session.sessionId, activationID: activationID)
                )
            },
            bindingLoader: { _ in
                await self.resolvedBinding(for: session.sessionId, modelContext: modelContext)?.remoteSessionID
            },
            bindingPersister: { _, handshake in
                await self.persistBinding(
                    sessionID: session.sessionId,
                    remoteSessionID: handshake.remoteSessionID,
                    configuration: configuration,
                    handshake: handshake,
                    selectedModel: nil,
                    modelContext: modelContext
                )
                await MainActor.run {
                    self.sessionStateStore.state(for: session.sessionId).remoteSessionID = handshake.remoteSessionID
                }
            }
        )
    }

    private func bindingStore(in modelContext: ModelContext) -> ACPExternalSessionBindingStore {
        ACPExternalSessionBindingStore(modelContext: modelContext)
    }

    func remoteCommands(localSessionID: String, remoteSessionID: String) -> [ACPCommandDescriptor] {
        sessionStateStore.existingState(for: localSessionID)?.commands(for: id, remoteSessionID: remoteSessionID) ?? []
    }

    func remoteCommands(localSessionID: String) -> [ACPCommandDescriptor] {
        if let cached = sessionStateStore.existingState(for: localSessionID)?.commands(for: id),
           !cached.isEmpty {
            debugLog(
                "remoteCommands hit session cache localSession=\(localSessionID) count=\(cached.count) names=\(cached.map(\.name).joined(separator: ","))"
            )
            return cached
        }

        guard let remoteSessionID = sessionStateStore.existingState(for: localSessionID)?.remoteSessionID else {
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
        sessionStateStore.existingState(for: localSessionID)?.plan()
    }

    func remoteSessionConfiguration(localSessionID: String) -> ACPExternalAgentSessionConfigurationSnapshot? {
        sessionStateStore.existingState(for: localSessionID)?.sessionConfiguration(for: id)
    }

    func updateSessionMode(session: Session, modelContext: ModelContext, modeID: String) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let configuration = resolveConfiguration(for: session, settings: settings)
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

        let activation = try await ensureRemoteSessionPrepared(
            session: session,
            configuration: configuration,
            settings: settings,
            modelContext: modelContext,
            authorizationPolicy: authorizationPolicy,
            workingDirectoryOverride: nil
        )

        try await activation.runtimeClient.setSessionMode(modeID, sessionID: activation.handshake.remoteSessionID)
        try applyFeatureEvents(
            [
                .updateCurrentMode(
                    providerID: id,
                    remoteSessionID: activation.handshake.remoteSessionID,
                    currentModeID: modeID
                )
            ],
            localSessionID: session.sessionId,
            modelContext: modelContext
        )
    }

    func updateSessionConfigOption(session: Session, modelContext: ModelContext, configID: String, value: String) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let configuration = resolveConfiguration(for: session, settings: settings)
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

        let activation = try await ensureRemoteSessionPrepared(
            session: session,
            configuration: configuration,
            settings: settings,
            modelContext: modelContext,
            authorizationPolicy: authorizationPolicy,
            workingDirectoryOverride: nil
        )

        let configOptions = try await activation.runtimeClient.setSessionConfigOption(
            configID,
            value: value,
            sessionID: activation.handshake.remoteSessionID
        )
        try applyFeatureEvents(
            [
                .replaceSessionConfiguration(
                    ACPExternalSessionConfigurationDraft(
                        providerID: id,
                        remoteSessionID: activation.handshake.remoteSessionID,
                        configOptions: configOptions,
                        modes: nil
                    )
                )
            ],
            localSessionID: session.sessionId,
            modelContext: modelContext
        )
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
        sessionStateStore.state(for: localSessionID).featureStore(modelContext: modelContext)
    }

    private func resolvedProjectedConfigOptions(
        explicitOptions: [ACPSessionConfigOption]?,
        localSessionID: String,
        remoteSessionID: String,
        handshakeConfigOptions: [ACPSessionConfigOption],
        selections: [ACPExternalSessionConfigSelection]
    ) -> [ACPSessionConfigOption]? {
        if let explicitOptions, explicitOptions.isEmpty == false {
            return explicitOptions
        }

        guard selections.isEmpty == false else {
            return nil
        }

        let existingOptions = sessionStateStore.existingState(for: localSessionID)?.sessionConfiguration(
            for: id,
            remoteSessionID: remoteSessionID
        )?.configOptions
        let baseOptions: [ACPSessionConfigOption]
        if let existingOptions, existingOptions.isEmpty == false {
            baseOptions = existingOptions
        } else {
            baseOptions = handshakeConfigOptions
        }
        guard baseOptions.isEmpty == false else {
            return nil
        }

        return baseOptions.map { option in
            var updatedOption = option
            if let selection = selections.first(where: {
                $0.configID == option.id?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }) {
                updatedOption.currentValue = selection.value
            }
            return updatedOption
        }
    }

    private func remoteSessionID(for update: CopilotACPUpdate, localSessionID: String) -> String? {
        switch update {
        case .session:
            return sessionStateStore.existingState(for: localSessionID)?.remoteSessionID
        case .sessionNotification(let notification):
            return trimmedNonEmpty(notification.sessionID) ?? sessionStateStore.existingState(for: localSessionID)?.remoteSessionID
        case .permission(let request):
            return trimmedNonEmpty(request.sessionID) ?? sessionStateStore.existingState(for: localSessionID)?.remoteSessionID
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
            case .currentModeUpdate:
                return "currentModeUpdate"
            case .configOptionUpdate:
                return "configOptionUpdate"
            case .sessionInfoUpdate:
                return "sessionInfoUpdate"
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
            case .currentModeUpdate:
                return "currentModeUpdate"
            case .configOptionUpdate:
                return "configOptionUpdate"
            case .sessionInfoUpdate:
                return "sessionInfoUpdate"
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
            case .replaceSessionConfiguration(let snapshot):
                return "replaceSessionConfiguration[configOptions=\(snapshot.configOptions?.count ?? 0) hasModes=\(snapshot.modes != nil)]"
            case .updateCurrentMode(_, _, let currentModeID):
                return "updateCurrentMode[currentMode=\(currentModeID)]"
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
