import Foundation
import SwiftData

@MainActor
protocol RemoteAgentExecuting {
    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        modelContext: ModelContext
    ) async throws -> String
}

@MainActor
struct RemoteAgentOrchestrator {
    private let router: RemoteConversationRouter
    private let executor: any RemoteAgentExecuting
    private let deliveryCoordinator: OutboundDeliveryCoordinator

    init(
        router: RemoteConversationRouter,
        executor: any RemoteAgentExecuting,
        deliveryCoordinator: OutboundDeliveryCoordinator
    ) {
        self.router = router
        self.executor = executor
        self.deliveryCoordinator = deliveryCoordinator
    }

    func handleInbound(
        _ message: InboundChannelMessage,
        authorizationPolicy: ToolAuthorizationPolicy,
        executionPolicy: RemoteExecutionPolicy,
        modelContext: ModelContext
    ) async throws {
        let session = try router.resolveSession(for: message, modelContext: modelContext)
        let userMessage = Message.userMessage(text: message.text, session: session)
        userMessage.status = .completed
        modelContext.insert(userMessage)
        try modelContext.save()

        do {
            let output = try await executor.execute(
                message: message,
                session: session,
                policy: executionPolicy,
                authorizationPolicy: authorizationPolicy,
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
    let authorizationResolver: ToolAuthorizationResolving
    let runtimeSettingsFactory: AuthorizedRuntimeSettingsFactory

    init(
        claudeService: ClaudeService,
        authorizationResolver: ToolAuthorizationResolving = ToolAuthorizationResolver(),
        runtimeSettingsFactory: AuthorizedRuntimeSettingsFactory = AuthorizedRuntimeSettingsFactory()
    ) {
        self.claudeService = claudeService
        self.authorizationResolver = authorizationResolver
        self.runtimeSettingsFactory = runtimeSettingsFactory
    }

    func execute(
        message: InboundChannelMessage,
        session: Session,
        policy: RemoteExecutionPolicy,
        authorizationPolicy: ToolAuthorizationPolicy,
        modelContext: ModelContext
    ) async throws -> String {
        let baseSettings = AppSettings.getOrCreate(in: modelContext)
        let snapshot = authorizationResolver.resolve(
            ToolAuthorizationRequest(
                context: .mainAgent,
                settings: baseSettings,
                subjectPolicy: authorizationPolicy
            )
        )
        let runtimeSettings = runtimeSettingsFactory.makeRuntimeSettings(
            base: baseSettings,
            snapshot: snapshot,
            workingDirectory: baseSettings.workingDirectory,
            enabledSkillNames: [],
            autoStartLSPServers: false
        )
        let result = try await claudeService.executeRemoteTurn(
            text: message.text,
            session: session,
            runtimeSettings: runtimeSettings,
            modelContext: modelContext,
            maxRounds: policy.maxRounds
        )
        return result.text
    }
}