//
//  ClaudeService+Messaging.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Messaging

    func bootstrapExecutionRuntime(modelContext: ModelContext) async {
        _ = await resolveExecutionOrchestrator(for: modelContext)
    }

    func sendMessage(
        text: String,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        modelContext: ModelContext
    ) async throws {
        lastError = nil
        do {
            let orchestrator = await resolveExecutionOrchestrator(for: modelContext)
            let command = resolveEnqueueCommand(
                text: text,
                session: session,
                modelId: modelId,
                providerID: ConversationExecutionProviderRegistry.resolveProviderID(
                    for: session,
                    settings: AppSettings.getOrCreate(in: modelContext)
                ),
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: directives,
                modelContext: modelContext
            )
            _ = try await orchestrator.enqueue(command)
            return
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
        lastError = nil
        do {
            let orchestrator = await resolveExecutionOrchestrator(for: modelContext)
            guard let command = try await resolveRegenerateCommand(
                session: session,
                modelId: modelId,
                modelContext: modelContext
            ) else {
                return
            }
            _ = try await orchestrator.enqueue(command)
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
        lastError = nil
        do {
            let orchestrator = await resolveExecutionOrchestrator(for: modelContext)
            let command = try await resolveEditAndResendCommand(
                message: message,
                newText: newText,
                session: session,
                modelId: modelId,
                modelContext: modelContext
            )
            _ = try await orchestrator.enqueue(command)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func cancelExecution(session: Session, modelContext: ModelContext) async {
        if let executionOrchestrator {
            await executionOrchestrator.cancelRunning(in: session.sessionId)
            return
        }

        let registry = executionProviderRegistry(for: modelContext)
        for provider in registry.allProviders {
            await provider.cancel(session: session, modelContext: modelContext)
        }
    }

    private func resolveEnqueueCommand(
        text: String,
        session: Session,
        modelId: String,
        providerID: ConversationExecutionProviderID,
        selectedFilePath: String?,
        selectedText: String?,
        directives: [ChatInputDirective],
        modelContext: ModelContext
    ) -> EnqueueExecutionCommand {
        let sourceUserMessageID = resolveOrCreateSourceUserMessageID(
            text: text,
            session: session,
            modelContext: modelContext
        )

        return EnqueueExecutionCommand(
            sessionID: session.sessionId,
            providerID: providerID,
            payload: .userPrompt(
                text: text,
                modelID: modelId,
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: directives
            ),
            sourceUserMessageID: sourceUserMessageID
        )
    }

    private func resolveRegenerateCommand(
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws -> EnqueueExecutionCommand? {
        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        guard let lastUser = sortedMessages.last(where: { $0.direction == .user }),
              let lastUserText = lastUser.textContent,
              !lastUserText.isEmpty else {
            return nil
        }

        for message in sortedMessages where message.sequence > lastUser.sequence {
            modelContext.delete(message)
        }
        try? modelContext.save()

        let settings = AppSettings.getOrCreate(in: modelContext)
        let registry = executionProviderRegistry(for: modelContext)
        let providerID = ConversationExecutionProviderRegistry.resolveProviderID(for: session, settings: settings)
        await registry.provider(for: providerID).resetSessionState(session: session, modelContext: modelContext)

        return EnqueueExecutionCommand(
            sessionID: session.sessionId,
            providerID: providerID,
            payload: .userPrompt(
                text: lastUserText,
                modelID: modelId,
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: lastUser.id
        )
    }

    private func resolveEditAndResendCommand(
        message: Message,
        newText: String,
        session: Session,
        modelId: String,
        modelContext: ModelContext
    ) async throws -> EnqueueExecutionCommand {
        message.textContent = newText

        let sortedMessages = session.messages.sorted { $0.sequence < $1.sequence }
        for trailingMessage in sortedMessages where trailingMessage.sequence > message.sequence {
            modelContext.delete(trailingMessage)
        }
        try? modelContext.save()

        let settings = AppSettings.getOrCreate(in: modelContext)
        let registry = executionProviderRegistry(for: modelContext)
        let providerID = ConversationExecutionProviderRegistry.resolveProviderID(for: session, settings: settings)
        await registry.provider(for: providerID).resetSessionState(session: session, modelContext: modelContext)

        return EnqueueExecutionCommand(
            sessionID: session.sessionId,
            providerID: providerID,
            payload: .userPrompt(
                text: newText,
                modelID: modelId,
                selectedFilePath: nil,
                selectedText: nil,
                directives: []
            ),
            sourceUserMessageID: message.id
        )
    }

    private func resolveExecutionOrchestrator(for modelContext: ModelContext) async -> ConversationExecutionOrchestrator {
        if let executionOrchestrator {
            await executionOrchestrator.restorePendingJobs()
            return executionOrchestrator
        }

        let orchestrator = ConversationExecutionOrchestrator(
            modelContext: modelContext,
            persistenceStore: ExecutionPersistenceStore(
                modelContext: modelContext,
                persistenceCoordinator: .shared
            ),
            projectionStore: executionProjectionStore,
            scheduler: ExecutionScheduler(maxConcurrentJobs: 2),
            runtimePool: ExecutionRuntimePool(),
            providerRegistry: executionProviderRegistry(for: modelContext),
            runtimeCoordinator: executionRuntimeCoordinator,
            changeReviewProjectionStore: changeReviewProjectionStore
        )
        executionOrchestrator = orchestrator
        await orchestrator.restorePendingJobs()
        return orchestrator
    }

    private func resolveOrCreateSourceUserMessageID(
        text: String,
        session: Session,
        modelContext: ModelContext
    ) -> UUID {
        if let existingMessageID = session.messages
            .sorted(by: { $0.sequence < $1.sequence })
            .last(where: { $0.direction == .user && $0.textContent == text })?
            .id {
            return existingMessageID
        }

        let message = Message.userMessage(text: text, session: session)
        message.status = .completed
        modelContext.insert(message)
        return message.id
    }

    func handleExecutionProviderSelectionChange(
        session: Session,
        selectedProviderID: ConversationExecutionProviderID,
        modelContext: ModelContext
    ) async {
        print(
            "[ExecutionProviderSelection] localSession=\(session.sessionId) selectedProvider=\(selectedProviderID.rawValue)"
        )
        let registry = executionProviderRegistry(for: modelContext)
        let activeProvider = registry.allProviders.first(where: { $0.id == selectedProviderID }) ?? registry.builtIn
        await executionRuntimeCoordinator.prepareForActivation(
            session: session,
            activeProvider: activeProvider,
            registry: registry,
            modelContext: modelContext
        )
    }

    // MARK: - Resume Helper

    func sendMessageBuiltIn(
        text: String,
        session: Session,
        modelId: String,
        selectedFilePath: String? = nil,
        selectedText: String? = nil,
        directives: [ChatInputDirective] = [],
        targetAgentMessageID: UUID? = nil,
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
            targetAgentMessageID: targetAgentMessageID,
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
                    self.getExternalACPTerminalTaskRuntime(
                        for: sessionID,
                        providerID: .githubCopilotCLI,
                        workingDirectory: workingDirectory
                    )
                },
                permissionCenter: acpPermissionCenter
            ),
            openCode: OpenCodeCLIExecutionProvider(
                terminalRuntimeFactory: { [unowned self] sessionID, workingDirectory in
                    self.getExternalACPTerminalTaskRuntime(
                        for: sessionID,
                        providerID: .openCodeCLI,
                        workingDirectory: workingDirectory
                    )
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
        targetAgentMessageID: UUID? = nil,
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

        let assistantMessage = resolveOrCreateAssistantMessage(
            session: session,
            targetAgentMessageID: targetAgentMessageID,
            modelContext: modelContext
        )

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
        } catch is CancellationError {
            assistantMessage.status = .cancelled
            if assistantMessage.textContent?.isEmpty ?? true {
                assistantMessage.textContent = "(已取消)"
            }
            session.updatedAt = Date()
            try? modelContext.save()
            throw CancellationError()
        } catch {
            assistantMessage.status = .failed
            assistantMessage.textContent = "错误: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw ClaudeError.streamFailed(error)
        }

        session.updatedAt = Date()
        try? modelContext.save()
    }

    private func resolveOrCreateAssistantMessage(
        session: Session,
        targetAgentMessageID: UUID?,
        modelContext: ModelContext
    ) -> Message {
        if let targetAgentMessageID,
           let existingMessage = session.messages.first(where: { $0.id == targetAgentMessageID }) {
            existingMessage.status = .pending
            existingMessage.errorMessage = nil
            if existingMessage.textContent == nil {
                existingMessage.textContent = ""
            }
            try? modelContext.save()
            return existingMessage
        }

        let assistantMessage = Message.agentMessage(text: "", session: session)
        assistantMessage.status = .pending
        modelContext.insert(assistantMessage)
        try? modelContext.save()
        return assistantMessage
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