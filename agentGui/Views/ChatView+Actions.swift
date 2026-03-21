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

    private func resolvedBuiltInModelID(settings: AppSettings) -> String {
        SessionExecutionPreferencesResolver.builtInModelID(for: session, settings: settings)
    }

    private func resolvedCopilotConfiguration(settings: AppSettings) -> GitHubCopilotCLIConfiguration {
        SessionExecutionPreferencesResolver.gitHubCopilotCLIConfiguration(for: session, settings: settings)
    }

    private func resolvedOpenCodeConfiguration(settings: AppSettings) -> OpenCodeCLIConfiguration {
        SessionExecutionPreferencesResolver.openCodeCLIConfiguration(for: session, settings: settings)
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

    var copilotComposerModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return resolvedCopilotConfiguration(settings: settings).defaultModel
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                let fallback = settings.githubCopilotCLIConfiguration.defaultModel
                updateSessionExecutionPreferences { preferences in
                    preferences.gitHubCopilotCLI.modelID = normalizedOptionalModelID(newValue, comparedTo: fallback)
                }
            }
        )
    }

    var copilotComposerApprovalModeSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return resolvedCopilotConfiguration(settings: settings).normalizedApprovalMode.rawValue
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                let fallback = settings.githubCopilotCLIConfiguration.defaultApprovalMode
                updateSessionExecutionPreferences { preferences in
                    preferences.gitHubCopilotCLI.approvalMode = normalizedCopilotApprovalOverride(newValue, comparedTo: fallback)
                }
            }
        )
    }

    var openCodeComposerModelSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return resolvedOpenCodeConfiguration(settings: settings).defaultModel
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                let fallback = settings.openCodeCLIConfiguration.defaultModel
                updateSessionExecutionPreferences { preferences in
                    preferences.openCodeCLI.modelID = normalizedOptionalModelID(newValue, comparedTo: fallback)
                }
            }
        )
    }

    var openCodeComposerApprovalModeSelectionBinding: Binding<String> {
        Binding(
            get: {
                let settings = AppSettings.getOrCreate(in: modelContext)
                return GitHubCopilotCLIApprovalModeOption.resolved(from: resolvedOpenCodeConfiguration(settings: settings).defaultApprovalMode).rawValue
            },
            set: { newValue in
                let settings = AppSettings.getOrCreate(in: modelContext)
                let fallback = settings.openCodeCLIConfiguration.defaultApprovalMode
                updateSessionExecutionPreferences { preferences in
                    preferences.openCodeCLI.approvalMode = normalizedCopilotApprovalOverride(newValue, comparedTo: fallback)
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
        if resolvedExecutionProviderID == .githubCopilotCLI {
            await refreshCopilotComposerAvailabilityStatus()
        } else if resolvedExecutionProviderID == .openCodeCLI {
            await refreshOpenCodeComposerAvailabilityStatus()
        }
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
            _ = try claudeService.resolveTurnSkillContext(
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

    var resolvedExecutionProviderID: ConversationExecutionProviderID {
        ConversationExecutionProviderRegistry.resolveProviderID(
            for: session,
            settings: AppSettings.getOrCreate(in: modelContext)
        )
    }

    var executionProviderSelectionBinding: Binding<ConversationExecutionProviderID> {
        Binding(
            get: { resolvedExecutionProviderID },
            set: { newValue in
                let previousValue = resolvedExecutionProviderID
                session.defaultExecutionProviderID = newValue.rawValue
                try? modelContext.save()
                if previousValue != newValue {
                    Task {
                        await claudeService.handleExecutionProviderSelectionChange(
                            session: session,
                            selectedProviderID: newValue,
                            modelContext: modelContext
                        )
                    }
                }
            }
        )
    }

    var executionProviderSelectionRawValueBinding: Binding<String> {
        Binding(
            get: { resolvedExecutionProviderID.rawValue },
            set: { newValue in
                guard let providerID = ConversationExecutionProviderID(rawValue: newValue) else {
                    return
                }
                executionProviderSelectionBinding.wrappedValue = providerID
            }
        )
    }

    var copilotComposerAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus {
        executionProviderAvailabilityModel.copilotStatus
    }

    var openCodeComposerAvailabilityStatus: OpenCodeCLIAvailabilityStatus {
        executionProviderAvailabilityModel.openCodeStatus
    }

    var copilotComposerAvailabilityRefreshToken: String {
        let settings = AppSettings.getOrCreate(in: modelContext)
        return "\(session.defaultExecutionProviderID)|\(settings.githubCopilotCLIConfigurationJSON)|\(settings.openCodeCLIConfigurationJSON)"
    }

    func refreshCopilotComposerAvailabilityStatus() async {
        let settings = AppSettings.getOrCreate(in: modelContext)
        await executionProviderAvailabilityModel.refreshCopilotStatus(
            configuration: settings.githubCopilotCLIConfiguration
        )
    }

    func refreshOpenCodeComposerAvailabilityStatus() async {
        let settings = AppSettings.getOrCreate(in: modelContext)
        await executionProviderAvailabilityModel.refreshStatus(
            for: .openCodeCLI,
            executablePath: settings.openCodeCLIConfiguration.executablePath
        )
    }

    func sendReadinessError(settings: AppSettings) -> String? {
        if sessionInteractionPolicy.canSend == false {
            return sessionInteractionPolicy.readOnlyReason
        }

        switch resolvedExecutionProviderID {
        case .builtInAgent:
            return claudeService.isConfigured ? "" : "请先在「设置」中配置 Anthropic API Key"
        case .githubCopilotCLI:
            let status = copilotComposerAvailabilityStatus
            return status.kind == .available ? "" : status.summaryText
        case .openCodeCLI:
            let status = openCodeComposerAvailabilityStatus
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
