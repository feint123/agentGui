import Foundation
import OSLog
import SwiftData

@MainActor
final class ChannelRuntimeBootstrap {
    private static let logger = Logger(subsystem: "com.agentgui", category: "Channels")

    private let registry: IMChannelRegistry
    private let orchestrator: RemoteAgentOrchestrator
    private let deduplicator: ChannelEventDeduplicator
    private let inboundTaskScheduler: ChannelInboundTaskScheduler

    init(
        registry: IMChannelRegistry,
        orchestrator: RemoteAgentOrchestrator,
        deduplicator: ChannelEventDeduplicator,
        inboundTaskScheduler: ChannelInboundTaskScheduler? = nil
    ) {
        self.registry = registry
        self.orchestrator = orchestrator
        self.deduplicator = deduplicator
        self.inboundTaskScheduler = inboundTaskScheduler ?? ChannelInboundTaskScheduler(
            executor: { [orchestrator] request in
                try await orchestrator.handleInbound(
                    request.message,
                    authorizationPolicy: request.authorizationPolicy,
                    executionPolicy: request.executionPolicy,
                    modelContext: request.modelContext
                )
            },
            failureHandler: { request, error in
                let summary = error is CancellationError ? "cancelled" : error.localizedDescription
                Self.logger.error(
                    "channel inbound execution failed kind=\(request.message.channelKind.rawValue, privacy: .public) conversation=\(request.message.externalConversationID, privacy: .public) message=\(request.message.externalMessageID, privacy: .public) error=\(summary, privacy: .public)"
                )
            }
        )
    }

    func registerDefaultAdaptersIfNeeded() {
        if registry.adapter(for: .feishu) == nil {
            registry.register(FeishuChannelAdapter())
        }
    }

    func startEnabledChannels(modelContext: ModelContext) async throws {
        let bindings = try modelContext.fetch(FetchDescriptor<ChannelAccountBinding>())
        for binding in bindings where binding.isEnabled {
            let executionPolicy = RemoteExecutionPolicy()
            let authorizationPolicy = binding.authorizationPolicy
            let configuration = IMChannelConfiguration(
                accountBinding: binding,
                authorizationPolicy: authorizationPolicy,
                executionPolicy: executionPolicy
            ) { [deduplicator, inboundTaskScheduler] message in
                let accepted = try deduplicator.acceptInbound(message, modelContext: modelContext)
                guard accepted else { return }
                await inboundTaskScheduler.submit(
                    ChannelInboundExecutionRequest(
                        message: message,
                        authorizationPolicy: authorizationPolicy,
                        executionPolicy: executionPolicy,
                        modelContext: modelContext
                    )
                )
            }
            try await registry.start(kind: binding.channelKind, configuration: configuration)
        }
    }

    func stopDisabledChannels(modelContext: ModelContext) async {
        let bindings = (try? modelContext.fetch(FetchDescriptor<ChannelAccountBinding>())) ?? []
        let enabledKinds = Set(bindings.filter(\.isEnabled).map(\.channelKind))

        for kind in IMChannelKind.allCases where !enabledKinds.contains(kind) {
            await inboundTaskScheduler.cancelTasks(for: kind)
            await registry.stop(kind: kind)
        }
    }

    func waitForIdle() async {
        await inboundTaskScheduler.waitUntilIdle()
    }
}