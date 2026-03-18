import Foundation
import SwiftData

@MainActor
protocol RemoteAgentExecuting {
    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        modelContext: ModelContext
    ) async throws -> String
}

@MainActor
struct RemoteAgentOrchestrator {
    private let router: RemoteConversationRouter
    private let executor: any RemoteAgentExecuting
    private let deliveryCoordinator: OutboundDeliveryCoordinator
    private let policyResolver: @Sendable (InboundChannelMessage, ModelContext) -> RemoteExecutionPolicy

    init(
        router: RemoteConversationRouter,
        executor: any RemoteAgentExecuting,
        deliveryCoordinator: OutboundDeliveryCoordinator,
        policyResolver: @escaping @Sendable (InboundChannelMessage, ModelContext) -> RemoteExecutionPolicy = { _, _ in
            RemoteExecutionPolicy()
        }
    ) {
        self.router = router
        self.executor = executor
        self.deliveryCoordinator = deliveryCoordinator
        self.policyResolver = policyResolver
    }

    func handleInbound(_ message: InboundChannelMessage, modelContext: ModelContext) async throws {
        let session = try router.resolveSession(for: message, modelContext: modelContext)
        let userMessage = Message.userMessage(text: message.text, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try modelContext.save()

        let policy = policyResolver(message, modelContext)

        do {
            let output = try await executor.execute(
                message: message,
                session: session,
                policy: policy,
                modelContext: modelContext
            )
            let responseText = output.isEmpty ? "(无响应)" : output
            let agentMessage = Message.agentMessage(text: responseText, session: session)
            agentMessage.status = .completed
            modelContext.insert(agentMessage)
            session.updatedAt = message.receivedAt
            try modelContext.save()

            let outbound = OutboundChannelMessage(
                channelKind: message.channelKind,
                externalConversationID: message.externalConversationID,
                text: responseText,
                replyToExternalMessageID: message.externalMessageID
            )
            _ = try await deliveryCoordinator.deliver(outbound, sourceMessage: agentMessage, modelContext: modelContext)
        } catch {
            let failureSummary = "执行失败：\(error.localizedDescription)"
            let failureMessage = Message.systemMessage(text: failureSummary, session: session)
            failureMessage.status = .failed
            modelContext.insert(failureMessage)
            session.updatedAt = message.receivedAt
            try modelContext.save()

            let outbound = OutboundChannelMessage(
                channelKind: message.channelKind,
                externalConversationID: message.externalConversationID,
                text: failureSummary,
                replyToExternalMessageID: message.externalMessageID
            )
            _ = try await deliveryCoordinator.deliver(outbound, sourceMessage: failureMessage, modelContext: modelContext)
        }
    }
}

@MainActor
struct ClaudeRemoteAgentExecutor: RemoteAgentExecuting {
    let claudeService: ClaudeService

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        modelContext: ModelContext
    ) async throws -> String {
        let baseSettings = AppSettings.getOrCreate(in: modelContext)
        let runtimeSettings = makeRuntimeSettings(from: baseSettings, policy: policy)
        let result = try await claudeService.executeRemoteTurn(
            text: message.text,
            session: session,
            runtimeSettings: runtimeSettings,
            modelContext: modelContext,
            maxRounds: policy.maxRounds
        )
        return result.text
    }

    private func makeRuntimeSettings(from settings: AppSettings, policy: RemoteExecutionPolicy) -> AppSettings {
        let runtimeSettings = AppSettings()
        runtimeSettings.apiKey = settings.apiKey
        runtimeSettings.baseURL = settings.baseURL
        runtimeSettings.selectedModel = settings.selectedModel
        runtimeSettings.themeMode = settings.themeMode
        runtimeSettings.messageFontSize = settings.messageFontSize
        runtimeSettings.enableTextEditorTool = settings.enableTextEditorTool && policy.allowFileWrite
        runtimeSettings.enableBashTool = settings.enableBashTool && policy.allowBash
        runtimeSettings.workingDirectory = settings.workingDirectory
        runtimeSettings.enableExtendedThinking = settings.enableExtendedThinking
        runtimeSettings.extendedThinkingBudget = settings.extendedThinkingBudget
        runtimeSettings.enabledSkillNames = []
        runtimeSettings.enableWebSearchTool = settings.enableWebSearchTool && policy.allowNetworkTools
        runtimeSettings.enableWebFetchTool = settings.enableWebFetchTool && policy.allowNetworkTools
        runtimeSettings.enableLSPTools = false
        runtimeSettings.autoStartLSPServers = false
        runtimeSettings.lspDefaultRoutingMode = settings.lspDefaultRoutingMode
        runtimeSettings.lspCustomServerProfiles = settings.lspCustomServerProfiles
        runtimeSettings.lspInstalledProviders = settings.lspInstalledProviders
        runtimeSettings.lspInstalledServerDefinitions = settings.lspInstalledServerDefinitions
        runtimeSettings.lspManualWorkspaceBindingsJSON = settings.lspManualWorkspaceBindingsJSON
        runtimeSettings.ollamaAPIKey = settings.ollamaAPIKey
        runtimeSettings.enableOllamaWebSearch = settings.enableOllamaWebSearch && policy.allowNetworkTools
        runtimeSettings.enableNetworkProxy = settings.enableNetworkProxy
        runtimeSettings.networkProxyURL = settings.networkProxyURL
        runtimeSettings.networkProxyBypassList = settings.networkProxyBypassList
        runtimeSettings.memoryEnabled = false
        runtimeSettings.memoryContextBudget = settings.memoryContextBudget
        runtimeSettings.backgroundAgentEnabled = settings.backgroundAgentEnabled
        runtimeSettings.backgroundAgentDefaultQoS = settings.backgroundAgentDefaultQoS
        runtimeSettings.backgroundAgentRequiresExternalPower = settings.backgroundAgentRequiresExternalPower
        runtimeSettings.backgroundAgentAllowNetworkTools = settings.backgroundAgentAllowNetworkTools
        runtimeSettings.backgroundAgentMaximumConcurrentRuns = settings.backgroundAgentMaximumConcurrentRuns
        runtimeSettings.backgroundAgentObservationRetentionDays = settings.backgroundAgentObservationRetentionDays
        return runtimeSettings
    }
}