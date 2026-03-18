import Foundation

struct IMChannelConfiguration {
    let accountBinding: ChannelAccountBinding
    let executionPolicy: RemoteExecutionPolicy
    let inboundMessageHandler: @MainActor @Sendable (InboundChannelMessage) async throws -> Void

    init(
        accountBinding: ChannelAccountBinding,
        executionPolicy: RemoteExecutionPolicy = RemoteExecutionPolicy(),
        inboundMessageHandler: @escaping @MainActor @Sendable (InboundChannelMessage) async throws -> Void
    ) {
        self.accountBinding = accountBinding
        self.executionPolicy = executionPolicy
        self.inboundMessageHandler = inboundMessageHandler
    }
}