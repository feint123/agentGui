//
//  ChatView+Actions.swift
//  agentGui
//

import SwiftUI
import SwiftData
import AppKit

extension ChatView {

    private func updateSessionExecutionPreferences(_ mutate: (inout SessionExecutionPreferences) -> Void) {
        var preferences = session.executionPreferences
        mutate(&preferences)
        session.executionPreferences = preferences
        try? modelContext.save()
    }

    private func normalizedOptionalModelID(_ modelID: String, comparedTo fallback: String) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed == fallback ? nil : trimmed
    }

    private func normalizedCopilotApprovalOverride(_ rawValue: String, comparedTo fallback: String) -> String? {
        let normalized = GitHubCopilotCLIApprovalModeOption.resolved(from: rawValue).rawValue
        return normalized == GitHubCopilotCLIApprovalModeOption.resolved(from: fallback).rawValue ? nil : normalized
    }

    func toggleVoiceInput() {
        guard sessionInteractionPolicy.canSend else {
            errorMessage = sessionInteractionPolicy.readOnlyReason
            return
        }

        clearSlashState()
        clearMentionStateIfNeeded()

        switch voiceInputController.phase {
        case .idle, .failed(_):
            let currentText = inputText
            activeTask = Task {
                @MainActor in
                await voiceInputController.startRecording(currentText: currentText)
            }
        case .requestingPermission, .preparing, .installingModel:
            activeTask = Task {
                @MainActor in
                await voiceInputController.cancelRecording()
            }
        case .recording, .finalizing:
            activeTask = Task {
                @MainActor in
                await voiceInputController.stopRecording()
            }
        }
    }

    func syncComposerTextFromVoiceControllerIfNeeded(_ text: String) {
        guard inputText != text else { return }
        inputText = text
        updateComposerAssistState(text)
    }

    func handleComposerTextChanged(_ text: String) {
        updateComposerAssistState(text)

        switch voiceInputController.phase {
        case .requestingPermission, .installingModel, .preparing, .recording, .finalizing:
            guard text != voiceInputController.displayedText else { return }
            Task {
                @MainActor in
                await voiceInputController.handleManualTextMutation(text)
            }
        case .idle, .failed(_):
            break
        }
    }

    private func resolvedBuiltInModelID(settings: AppSettings) -> String {
        SessionExecutionPreferencesResolver.builtInModelID(for: session, settings: settings)
    }

    var builtInComposerModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return resolvedBuiltInModelID(settings: settings)
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                updateSessionExecutionPreferences { preferences in
                    preferences.builtInModelID = normalizedOptionalModelID(newValue, comparedTo: settings.selectedModel)
                }
            }
        )
    }

    var builtInComposerApprovalModeSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return SessionExecutionPreferencesResolver.builtInApprovalMode(for: session, settings: settings).rawValue
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                let fallback = settings.builtInDefaultApprovalMode
                updateSessionExecutionPreferences { preferences in
                    preferences.builtInApprovalMode = normalizedCopilotApprovalOverride(newValue, comparedTo: fallback)
                }
            }
        )
    }

    // MARK: - Send Message

    func sendMessage() async {
        guard sessionInteractionPolicy.canSend else {
            errorMessage = sessionInteractionPolicy.readOnlyReason
            return
        }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        var fullText = trimmed
        let settings = AppSettings.getOrCreate(in: modelContext)
        await refreshComposerAvailabilityStatusIfNeeded()
        let preflightError = sendReadinessError(settings: settings) ?? sendReadinessFallbackMessage(settings: settings)
        if !preflightError.isEmpty {
            errorMessage = preflightError
            return
        }
        fullText = expandMentions(in: fullText, workingDirectory: settings.workingDirectory)

        // Build a parseable workspace context prefix from the current file path and/or selected text.
        var contextParts: [String] = []
        if showSelectionContext, let sel = workspaceState.editorSelectedText, !sel.isEmpty {
            if let fileURL = workspaceState.selectedFile {
                contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL, lineRange: workspaceState.editorSelectedLineRange))")
            } else if let lineRange = workspaceState.editorSelectedLineRange {
                contextParts.append("当前文件: :\(lineRange.displayText)")
            } else {
                contextParts.append("当前文件:")
            }
            contextParts.append("选区内容:\n\(sel)")
        } else if showFileContext, let fileURL = workspaceState.selectedFile {
            contextParts.append("当前文件: \(WorkspaceFileContextFormatter.inlineReference(for: fileURL))")
        }
        if !contextParts.isEmpty {
            fullText = contextParts.joined(separator: "\n") + "\n\n" + fullText
        }

        if !attachedFiles.isEmpty {
            let refs = attachedFiles.map { "- \($0.path)" }.joined(separator: "\n")
            fullText += "\n\nReferenced files:\n\(refs)"
        }

        do {
            _ = try await claudeService.resolveTurnSkillContext(
                enabledSkillNames: settings.enabledSkillNames,
                directives: activeInputDirectives
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let auditedText = ChatInputDirectiveAudit.appendAuditTrail(
            to: fullText,
            directives: activeInputDirectives
        )

        inputText = ""
        attachedFiles = []
        showFileContext = true
        showSelectionContext = true

        let userMessage = Message.userMessage(text: auditedText, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try? modelContext.save()

        let modelId = resolvedBuiltInModelID(settings: settings)
        let selectedFilePath: String?
        if showFileContext || showSelectionContext {
            selectedFilePath = workspaceState.selectedFile?.standardizedFileURL.path
        } else {
            selectedFilePath = nil
        }
        let selectedText = showSelectionContext ? workspaceState.editorSelectedText : nil

        do {
            try await claudeService.sendMessage(
                text: auditedText,
                session: session,
                modelId: modelId,
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: activeInputDirectives,
                modelContext: modelContext
            )
            activeInputDirectives = []
        } catch is CancellationError {
            // User stopped the stream — no error to show
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var resolvedExecutionProviderReference: ExecutionProviderReference {
        ConversationExecutionProviderRegistry.resolveProviderReference(
            for: session,
            settings: AppSettings.getOrCreate(in: modelContext)
        )
    }

    var resolvedExecutionProviderDisplayName: String {
        switch resolvedExecutionProviderReference {
        case .builtIn:
            return ConversationExecutionProviderID.builtInAgent.displayName
        case .externalACP:
            return currentExternalACPProfile?.displayName ?? "ACP Provider"
        }
    }

    private var currentExternalACPProfile: ACPProviderProfile? {
        guard case .externalACP = resolvedExecutionProviderReference,
              let registry = claudeService.executionProviderRegistry,
              let provider = registry.providerIfAvailable(for: resolvedExecutionProviderReference) as? DynamicACPExternalExecutionProvider else {
            return nil
        }

        return provider.profile
    }

    var currentACPConfigurationController: (any ACPRemoteSessionConfigurationControlling)? {
        guard resolvedExecutionProviderReference != .builtIn,
              let registry = claudeService.executionProviderRegistry,
              let provider = registry.provider(for: resolvedExecutionProviderReference) as? any ACPRemoteSessionConfigurationControlling else {
            return nil
        }

        return provider
    }

    var currentACPSessionConfigurationPresentation: ACPSessionConfigurationPresentation? {
        _ = acpConfigurationRefreshToken

        guard let snapshot = currentACPConfigurationController?.remoteSessionConfiguration(localSessionID: session.sessionId) else {
            return nil
        }

        return ACPSessionConfigurationPresentationBuilder.make(
            providerReference: resolvedExecutionProviderReference,
            providerDisplayName: resolvedExecutionProviderDisplayName,
            snapshot: snapshot
        )
    }

    private func persistACPModeSelection(_ modeID: String) {
        let providerReference = resolvedExecutionProviderReference
        updateSessionExecutionPreferences { preferences in
            preferences.applyACPModeSelection(providerReference: providerReference, modeID: modeID)
        }
    }

    private func persistACPConfigSelection(
        configID: String,
        value: String,
        presentation: ACPSessionConfigurationPresentation?
    ) {
        let providerReference = resolvedExecutionProviderReference
        updateSessionExecutionPreferences { preferences in
            preferences.applyACPConfigSelection(
            providerReference: providerReference,
                configID: configID,
                value: value,
                modelConfigID: presentation?.modelConfig?.id,
                approvalsConfigID: presentation?.approvalsConfig?.id
            )
        }
    }

    func updateACPMode(_ modeID: String) {
        guard let controller = currentACPConfigurationController else { return }
        Task {
            do {
                try await controller.updateSessionMode(session: session, modelContext: modelContext, modeID: modeID)
                await MainActor.run {
                    persistACPModeSelection(modeID)
                    acpConfigurationRefreshToken &+= 1
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateACPConfigOption(configID: String, value: String) {
        guard let controller = currentACPConfigurationController else { return }
        let presentation = currentACPSessionConfigurationPresentation
        Task {
            do {
                try await controller.updateSessionConfigOption(
                    session: session,
                    modelContext: modelContext,
                    configID: configID,
                    value: value
                )
                await MainActor.run {
                    persistACPConfigSelection(configID: configID, value: value, presentation: presentation)
                    acpConfigurationRefreshToken &+= 1
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    var composerAvailabilityStatus: ACPCLIAvailabilityStatus? {
        executionProviderAvailabilityModel.status(for: resolvedExecutionProviderReference)
    }

    var isRefreshingComposerAvailabilityStatus: Bool {
        executionProviderAvailabilityModel.isRefreshing(for: resolvedExecutionProviderReference)
    }

    var copilotComposerAvailabilityRefreshToken: String {
        let executablePath = currentExternalACPProfile?.executablePath ?? ""
        return "\(resolvedExecutionProviderReference.persistedValue)|\(executablePath)"
    }

    func refreshComposerAvailabilityStatusIfNeeded() async {
        guard let profile = currentExternalACPProfile else {
            return
        }

        await executionProviderAvailabilityModel.refreshStatus(
            for: resolvedExecutionProviderReference,
            executablePath: profile.executablePath,
            displayName: profile.displayName
        )
    }

    func sendReadinessError(settings: AppSettings) -> String? {
        if sessionInteractionPolicy.canSend == false {
            return sessionInteractionPolicy.readOnlyReason
        }

        switch resolvedExecutionProviderReference {
        case .builtIn:
            return claudeService.isConfigured ? "" : "请先在「设置」中配置 Anthropic API Key"
        case .externalACP:
            guard let registry = claudeService.executionProviderRegistry,
                  registry.providerIfAvailable(for: resolvedExecutionProviderReference) != nil else {
                return "当前 ACP Provider 不可用，请先在“设置 > 执行器”中启用并验证。"
            }

            if isRefreshingComposerAvailabilityStatus {
                return "正在检查 \(resolvedExecutionProviderDisplayName)…"
            }
            let status = composerAvailabilityStatus ?? .unknown
            return status.kind == .available ? "" : status.summaryText
        }
    }

    func sendReadinessFallbackMessage(settings: AppSettings) -> String {
        sendReadinessError(settings: settings) ?? "当前执行器不可用"
    }

    // MARK: - @ Mention Expansion

    /// Replaces @relPath tokens with their absolute path when the file exists under workingDirectory.
    func expandMentions(in text: String, workingDirectory: String) -> String {
        guard !workingDirectory.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"@(\S+)"#)
        else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        // Iterate in reverse so replacements don't shift earlier offsets
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let relRange = match.range(at: 1)
            let relPath = ns.substring(with: relRange)
            let absPath = (workingDirectory as NSString).appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: absPath) else { continue }
            if let swiftRange = Range(match.range(at: 0), in: result) {
                result.replaceSubrange(swiftRange, with: absPath)
            }
        }
        return result
    }

    // MARK: - Message Actions

    func copyMessage(_ message: Message) {
        let text = message.textContent ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func deleteMessage(_ message: Message) {
        _ = message.toolCalls
        _ = message.agentRounds
        modelContext.delete(message)
        try? modelContext.save()
    }

    func deleteFrom(_ message: Message) {
        deleteFromConfirmMessage = message
    }

    func confirmDeleteFrom(_ message: Message) {
        activeTask?.cancel()
        activeTask = nil
        let seq = message.sequence
        // Snapshot and pre-resolve faults before deletion
        let snapshot = allMessages.filter { $0.sequence >= seq }
        for msg in snapshot {
            _ = msg.toolCalls
            _ = msg.agentRounds
            modelContext.delete(msg)
        }
        try? modelContext.save()
    }

    func regenerate() {
        guard !effectiveStreamingState else { return }
        activeTask = Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.regenerate(
                    session: session,
                    modelId: resolvedBuiltInModelID(settings: settings),
                    modelContext: modelContext
                )
            } catch is CancellationError {
                // User stopped
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func editAndResend(message: Message, newText: String) {
        guard !effectiveStreamingState else { return }
        activeTask = Task {
            let settings = AppSettings.getOrCreate(in: modelContext)
            do {
                try await claudeService.editAndResend(
                    message: message,
                    newText: newText,
                    session: session,
                    modelId: resolvedBuiltInModelID(settings: settings),
                    modelContext: modelContext
                )
            } catch is CancellationError {
                // User stopped
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopStreaming() {
        activeTask?.cancel()
        activeTask = nil
        Task {
            await claudeService.cancelExecution(session: session, modelContext: modelContext)
        }
    }
}

// MARK: - Rewind Factory

extension ChatView {
    /// 构造 Rewind 基础依赖的工厂方法（FileBackupStore + RewindTransactionCoordinator）。
    /// 每次调用返回新实例（无状态，幂等）。
    func makeRewindDependencies() -> (FileBackupStore, RewindTransactionCoordinator) {
        let backupBaseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agentGui/checkpoints")
        let store = FileBackupStore(baseURL: backupBaseURL)
        let convCoord = ConversationRewindCoordinator(modelContext: modelContext)
        let fsCoord = FileSystemRewindCoordinator(fileBackupStore: store)
        let cs = claudeService
        let txCoord = RewindTransactionCoordinator(
            conversationRewindCoordinator: convCoord,
            fileSystemRewindCoordinator: fsCoord,
            cancelLoop: { [cs] sessionID, ctx in
                await cs.cancelExecution(session: session, modelContext: ctx)
            },
            modelContext: modelContext
        )
        return (store, txCoord)
    }

    /// 构造 MessageRewindSelectorView 所需的依赖。
    /// cancelLoop 捕获 claudeService，以闭包形式注入 RewindTransactionCoordinator（保持可测试性）。
    func makeRewindSelectorView() -> MessageRewindSelectorView {
        let (store, txCoord) = makeRewindDependencies()
        let checkpointService = ConversationCheckpointService(fileBackupStore: store)
        let inspector = RewindPreflightInspector(fileBackupStore: store)
        return MessageRewindSelectorView(
            session: session,
            allMessages: Array(allMessages),
            transactionCoordinator: txCoord,
            checkpointService: checkpointService,
            preflightInspector: inspector
        )
    }
}

// MARK: - R-D4: Context Menu Rewind

extension ChatView {

    /// 从消息上下文菜单触发回滚的入口。
    /// 构建 MessageRewindContextMenuCoordinator，异步执行决策逻辑，结果 dispatch 到 UI 状态。
    func initiateContextMenuRewind(message: Message) {
        Task { @MainActor in
            do {
                let (store, txCoord) = makeRewindDependencies()
                let checkpointService = ConversationCheckpointService(fileBackupStore: store)
                let inspector = RewindPreflightInspector(fileBackupStore: store)
                let coordinator = MessageRewindContextMenuCoordinator(
                    checkpointService: checkpointService,
                    preflightInspector: inspector,
                    transactionCoordinator: txCoord
                )
                let result = try await coordinator.execute(
                    message: message,
                    allMessages: Array(allMessages),
                    sessionID: session.sessionId,
                    modelContext: modelContext
                )
                switch result {
                case .losslessCompleted:
                    break  // rewindDidComplete 通知已由 txCoord 发出，ChatView 监听并填回输入框
                case .needsConfirmation(let pending):
                    contextMenuPendingConfirmation = pending
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 「确认回滚」sheet 批准后的执行入口。
    func executeContextMenuRewind(
        pending: MessageRewindSelectorViewModel.PendingConfirmation,
        option: RewindOption
    ) async {
        let (_, txCoord) = makeRewindDependencies()
        do {
            try await txCoord.execute(
                targetMessage: pending.message,
                checkpoint: pending.checkpoint,
                option: option,
                repopulateInput: true
            )
            contextMenuPendingConfirmation = nil
        } catch {
            errorMessage = error.localizedDescription
            contextMenuPendingConfirmation = nil
        }
    }
}
