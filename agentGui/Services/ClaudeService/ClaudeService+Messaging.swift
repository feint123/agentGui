//
//  ClaudeService+Messaging.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Messaging

    func sendMessage(
        text: String,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        modelContext: ModelContext
    ) async throws {
        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let settings = AppSettings.getOrCreate(in: modelContext)
        let provider = executionProviderRegistry(for: modelContext).provider(for: session, settings: settings)

        do {
            try await provider.send(
                ConversationExecutionRequest(
                    text: text,
                    session: session,
                    modelID: modelId,
                    selectedFilePath: selectedFilePath,
                    selectedText: selectedText,
                    directives: directives,
                    modelContext: modelContext
                )
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func regenerate(
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let settings = AppSettings.getOrCreate(in: modelContext)
        let provider = executionProviderRegistry(for: modelContext).provider(for: session, settings: settings)
        do {
            try await provider.regenerate(
                ConversationRegenerationRequest(
                    session: session,
                    modelID: modelId,
                    modelContext: modelContext
                )
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func editAndResend(
        message: Message,
        newText: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        isStreaming = true
        lastError = nil
        defer { isStreaming = false }

        let settings = AppSettings.getOrCreate(in: modelContext)
        let provider = executionProviderRegistry(for: modelContext).provider(for: session, settings: settings)
        do {
            try await provider.editAndResend(
                ConversationEditAndResendRequest(
                    message: message,
                    newText: newText,
                    session: session,
                    modelID: modelId,
                    modelContext: modelContext
                )
            )
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func cancelExecution(session: Session, modelContext: ModelContext) async {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let provider = executionProviderRegistry(for: modelContext).provider(for: session, settings: settings)
        await provider.cancel(session: session, modelContext: modelContext)
    }

    // MARK: - Resume Helper

    func sendMessageBuiltIn(
        text: String,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        let lastPersistedMessageMatchesCurrentTurn = sortedMessages.last.map {
            $0.direction == .user && $0.textContent == text
        } ?? false
        if !lastPersistedMessageMatchesCurrentTurn {
            apiMessages.append(MessageParameter.Message(role: .user, content: .text(text)))
        }

        let isFirstMessage = session.title == "新对话" || session.title.isEmpty

        try await resumeSendBuiltIn(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            selectedFilePath: selectedFilePath,
            selectedText: selectedText,
            directives: directives,
            modelContext: modelContext
        )

        if isFirstMessage {
            Task { await generateTitle(for: session, firstMessage: text, modelContext: modelContext) }
        }
    }

    func regenerateBuiltIn(
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        let lastUserSeq = sortedMessages.last(where: { $0.direction == .user })?.sequence ?? -1

        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages where msg.sequence <= lastUserSeq {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        guard !apiMessages.isEmpty else { return }

        for msg in sortedMessages where msg.sequence > lastUserSeq {
            modelContext.delete(msg)
        }
        try? modelContext.save()

        try await resumeSendBuiltIn(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )
    }

    func editAndResendBuiltIn(
        message: Message,
        newText: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws {
        guard let service else { throw ClaudeError.notConfigured }

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        message.textContent = newText

        var apiMessages: [MessageParameter.Message] = []
        for msg in sortedMessages where msg.sequence <= message.sequence {
            guard let content = msg.textContent, !content.isEmpty else { continue }
            let role: MessageParameter.Message.Role = msg.direction == .user ? .user : .assistant
            apiMessages.append(MessageParameter.Message(role: role, content: .text(content)))
        }
        guard !apiMessages.isEmpty else { return }

        for msg in sortedMessages where msg.sequence > message.sequence {
            modelContext.delete(msg)
        }
        try? modelContext.save()

        try await resumeSendBuiltIn(
            apiMessages: apiMessages,
            service: service,
            session: session,
            modelId: modelId,
            modelContext: modelContext
        )
    }

    private func executionProviderRegistry(for modelContext: ModelContext) -> ConversationExecutionProviderRegistry {
        if let executionProviderRegistry {
            return executionProviderRegistry
        }

        let registry = ConversationExecutionProviderRegistry(
            builtIn: BuiltInConversationExecutionProvider(claudeService: self),
            copilot: GitHubCopilotCLIExecutionProvider(
                terminalRuntimeFactory: { [unowned self] sessionID, workingDirectory in
                    self.getTerminalTaskRuntime(for: sessionID, workingDirectory: workingDirectory)
                },
                permissionCenter: acpPermissionCenter
            )
        )
        executionProviderRegistry = registry
        _ = modelContext
        return registry
    }

    private func resumeSendBuiltIn(
        apiMessages: [MessageParameter.Message],
        service: any AnthropicService,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        modelContext: ModelContext
    ) async throws {
        let settings = AppSettings.getOrCreate(in: modelContext)
        let turnSkillContext = try resolveTurnSkillContext(
            enabledSkillNames: settings.enabledSkillNames,
            directives: directives
        )
        let systemPrompt = buildSystemPrompt(
            skills: turnSkillContext.effectiveSkills,
            explicitlyActivatedSkills: turnSkillContext.explicitlyActivatedSkills,
            workingDirectory: settings.workingDirectory,
            settings: settings
        )
        let tools = buildTools(modelId: modelId, settings: settings, enabledSkills: turnSkillContext.effectiveSkills)

        currentSession = session
        await autoStartLSPServerForSelectedFileIfNeeded(
            workingDirectory: settings.workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )

        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        do {
            let result = try await runAgenticLoop(
                apiMessages: apiMessages,
                assistantMessage: assistantMessage,
                service: service,
                modelId: modelId,
                tools: tools,
                systemPrompt: systemPrompt,
                session: session,
                settings: settings,
                modelContext: modelContext,
            )
            assistantMessage.status = result.completedSuccessfully ? .completed : .failed
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(无响应)"
            }
        } catch {
            assistantMessage.status = .failed
            assistantMessage.textContent = "错误: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw ClaudeError.streamFailed(error)
        }

        session.updatedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Title Generation

    func generateTitle(for session: Session, firstMessage: String, modelContext: ModelContext) async {
        guard let service else { return }
        let prompt = "用不超过10个字概括这个对话主题（只输出标题，不加引号）：\(firstMessage)"
        let messages: [MessageParameter.Message] = [
            MessageParameter.Message(role: .user, content: .text(prompt))
        ]
        let parameters = MessageParameter(
            model: .other("claude-haiku-4-5"),
            messages: messages,
            maxTokens: 64
        )
        do {
            let response = try await service.createMessage(parameters)
            if case .text(let title, _) = response.content.first, !title.isEmpty {
                session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                try? modelContext.save()
            }
        } catch {
            session.title = String(firstMessage.prefix(30))
            try? modelContext.save()
        }
    }
}