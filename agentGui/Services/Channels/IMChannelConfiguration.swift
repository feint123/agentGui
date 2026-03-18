import Foundation

struct IMChannelConfiguration {
    let accountBinding: ChannelAccountBinding
    let authorizationPolicy: ToolAuthorizationPolicy
    let executionPolicy: RemoteExecutionPolicy
    let inboundMessageHandler: @MainActor @Sendable (InboundChannelMessage) async throws -> Void

    init(
        accountBinding: ChannelAccountBinding,
        authorizationPolicy: ToolAuthorizationPolicy? = nil,
        executionPolicy: RemoteExecutionPolicy = RemoteExecutionPolicy(),
        inboundMessageHandler: @escaping @MainActor @Sendable (InboundChannelMessage) async throws -> Void
    ) {
        self.accountBinding = accountBinding
        self.authorizationPolicy = authorizationPolicy ?? accountBinding.authorizationPolicy
        self.executionPolicy = executionPolicy
        self.inboundMessageHandler = inboundMessageHandler
    }
}