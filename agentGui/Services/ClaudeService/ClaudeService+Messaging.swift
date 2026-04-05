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
            let fallbackProviderReference = ConversationExecutionProviderRegistry.resolveProviderReference(
                for: session,
                settings: AppSettings.getOrCreate(in: modelContext)
            )
            let executionTarget = resolveExecutionTarget(
                session: session,
                fallbackProviderReference: fallbackProviderReference
            )
            let command = resolveEnqueueCommand(
                text: text,
                session: session,
                modelId: modelId,
                providerReference: executionTarget.providerReference,
                teamContext: executionTarget.teamContext,
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
        providerReference: ExecutionProviderReference,
        teamContext: AgentTeamExecutionContext?,
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
            providerReference: providerReference,
            payload: .userPrompt(
                text: text,
                modelID: modelId,
                selectedFilePath: selectedFilePath,
                selectedText: selectedText,
                directives: directives,
                teamContext: teamContext
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
        let fallbackProviderReference = ConversationExecutionProviderRegistry.resolveProviderReference(for: session, settings: settings)
        let executionTarget = resolveExecutionTarget(
            session: session,
            fallbackProviderReference: fallbackProviderReference
        )
        await registry.provider(for: executionTarget.providerReference).resetSessionState(session: session, modelContext: modelContext)

        return EnqueueExecutionCommand(
            sessionID: session.sessionId,
            providerReference: executionTarget.providerReference,
            payload: .userPrompt(
                text: lastUserText,
                modelID: modelId,
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                teamContext: executionTarget.teamContext
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
        let fallbackProviderReference = ConversationExecutionProviderRegistry.resolveProviderReference(for: session, settings: settings)
        let executionTarget = resolveExecutionTarget(
            session: session,
            fallbackProviderReference: fallbackProviderReference
        )
        await registry.provider(for: executionTarget.providerReference).resetSessionState(session: session, modelContext: modelContext)

        return EnqueueExecutionCommand(
            sessionID: session.sessionId,
            providerReference: executionTarget.providerReference,
            payload: .userPrompt(
                text: newText,
                modelID: modelId,
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                teamContext: executionTarget.teamContext
            ),
            sourceUserMessageID: message.id
        )
    }

    private func resolveExecutionTarget(
        session: Session,
        fallbackProviderReference: ExecutionProviderReference
    ) -> (providerReference: ExecutionProviderReference, teamContext: AgentTeamExecutionContext?) {
        guard session.kind == .agentTeam,
              let board = session.agentTeamState?.claimBoardState else {
            return (fallbackProviderReference, nil)
        }

        if let preferredTarget = board.preferredExecutionTarget() {
            return (preferredTarget.providerReference, preferredTarget.teamContext)
        }

        return (
            fallbackProviderReference,
            resolveTeamExecutionContext(session: session, providerReference: fallbackProviderReference)
        )
    }

    private func resolveTeamExecutionContext(
        session: Session,
        providerReference: ExecutionProviderReference
    ) -> AgentTeamExecutionContext? {
        guard session.kind == .agentTeam,
              let board = session.agentTeamState?.claimBoardState else {
            return nil
        }

        return board.executionContext(for: providerReference)
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
                persistenceCoordinator: .shared,
                recoveryRefreshSink: runtimeRecoveryRefreshSink
            ),
            projectionStore: executionProjectionStore,
            projectionWriter: SessionExecutionLifecycleFanoutWriter(
                projectionWriter: executionProjectionStore,
                runtimeBus: executionRuntimeBus
            ),
            scheduler: ExecutionScheduler(maxConcurrentJobs: 20),
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
        selectedProviderReference: ExecutionProviderReference,
        modelContext: ModelContext,
        trigger: ConversationExecutionActivationTrigger = .selection
    ) async {
        print(
            "[ExecutionProviderSelection] localSession=\(session.sessionId) selectedProvider=\(selectedProviderReference.persistedValue) trigger=\(String(describing: trigger))"
        )
        let registry = executionProviderRegistry(for: modelContext)
        let activeProvider = registry.provider(for: selectedProviderReference)
        await executionRuntimeCoordinator.prepareForActivation(
            session: session,
            activeProvider: activeProvider,
            registry: registry,
            modelContext: modelContext,
            trigger: trigger
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

        let registry = buildExecutionProviderRegistry(for: modelContext)
        executionProviderRegistry = registry
        return registry
    }

    func refreshExecutionProviderRuntime(for modelContext: ModelContext) {
        executionProviderRegistry = buildExecutionProviderRegistry(for: modelContext)
        executionOrchestrator = nil
    }

    func refreshExecutionProviderRuntimeChecked(for modelContext: ModelContext) throws {
        do {
            let registry = try checkedBuildExecutionProviderRegistry(for: modelContext)
            executionProviderRegistry = registry
            executionOrchestrator = nil
        } catch {
            executionProviderRegistry = fallbackExecutionProviderRegistry()
            executionOrchestrator = nil
            throw error
        }
    }

    func buildExecutionProviderRegistry(for modelContext: ModelContext) -> ConversationExecutionProviderRegistry {
        (try? checkedBuildExecutionProviderRegistry(for: modelContext))
            ?? fallbackExecutionProviderRegistry()
    }

    func checkedBuildExecutionProviderRegistry(for modelContext: ModelContext) throws -> ConversationExecutionProviderRegistry {
        let builtIn = BuiltInConversationExecutionProvider(claudeService: self)
        let repository = ACPProviderProfileRepository(modelContext: modelContext)
        let builder = DynamicACPProviderRegistryBuilder(
            repository: repository,
            providerFactory: { [externalStore = externalACPTerminalRuntimeStore, permissionCenter = acpPermissionCenter] profile in
                let providerReference = ExecutionProviderReference.externalACP(profileID: profile.id)
                return DynamicACPExternalExecutionProvider(
                    profile: profile,
                    terminalRuntimeFactory: { sessionID, workingDirectory in
                        await externalStore.runtime(
                            for: sessionID,
                            providerReference: providerReference,
                            workingDirectory: workingDirectory
                        )
                    },
                    sessionRuntimeResetter: { sessionID in
                        await externalStore.reset(
                            for: sessionID,
                            providerReference: providerReference
                        )
                    },
                    permissionCenter: permissionCenter
                )
            }
        )

        return try builder.build(builtIn: builtIn)
    }

    private func fallbackExecutionProviderRegistry() -> ConversationExecutionProviderRegistry {
        ConversationExecutionProviderRegistry(
            builtIn: BuiltInConversationExecutionProvider(claudeService: self),
            externalProviders: [:]
        )
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
        let turnSkillContext = try await resolveTurnSkillContext(
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

        // R-B1 pre-loop: 找到触发此 loop 的用户消息 ID，创建 accumulator
        let userMsgID = session.messages
            .sorted { $0.sequence < $1.sequence }
            .last(where: { $0.direction == .user })?.id ?? UUID()
        let wsRoot = settings.workingDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : settings.workingDirectory
        let checkpointAcc = ActiveCheckpointAccumulator(messageID: userMsgID, workspaceRoot: wsRoot)
        sessionCheckpointAccumulators[session.sessionId] = checkpointAcc

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

            // R-B1 post-loop: 将本轮 accumulator 条目持久化为 ConversationCheckpoint
            try? await checkpointService.makeSnapshot(
                accumulator: checkpointAcc,
                sessionID: session.sessionId,
                modelContext: modelContext
            )
        } catch is CancellationError {
            // 取消时仍尝试保存已收集的快照（loop 可能已完成部分工具调用）
            try? await checkpointService.makeSnapshot(
                accumulator: checkpointAcc,
                sessionID: session.sessionId,
                modelContext: modelContext
            )
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