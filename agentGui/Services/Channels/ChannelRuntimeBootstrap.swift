import Foundation
import SwiftData

@MainActor
final class ChannelRuntimeBootstrap {
    private let registry: IMChannelRegistry
    private let orchestrator: RemoteAgentOrchestrator
    private let deduplicator: ChannelEventDeduplicator

    init(
        registry: IMChannelRegistry,
        orchestrator: RemoteAgentOrchestrator,
        deduplicator: ChannelEventDeduplicator
    ) {
        self.registry = registry
        self.orchestrator = orchestrator
        self.deduplicator = deduplicator
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
            ) { [deduplicator, orchestrator] message in
                let accepted = try deduplicator.acceptInbound(message, modelContext: modelContext)
                guard accepted else { return }
                try await orchestrator.handleInbound(
                    message,
                    authorizationPolicy: authorizationPolicy,
                    executionPolicy: executionPolicy,
                    modelContext: modelContext
                )
            }
            try await registry.start(kind: binding.channelKind, configuration: configuration)
        }
    }

    func stopDisabledChannels(modelContext: ModelContext) async {
        let bindings = (try? modelContext.fetch(FetchDescriptor<ChannelAccountBinding>())) ?? []
        let enabledKinds = Set(bindings.filter(\.isEnabled).map(\.channelKind))

        for kind in IMChannelKind.allCases where !enabledKinds.contains(kind) {
            await registry.stop(kind: kind)
        }
    }
}