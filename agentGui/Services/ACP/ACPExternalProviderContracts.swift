import Foundation

@MainActor
protocol ACPExternalProviderRuntimeClient: AnyObject {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake
    func setModel(_ modelID: String, sessionID: String) async throws
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

struct ACPExternalProviderExecutionBehavior: Equatable, Sendable {
    let requiresCapabilityNegotiationForModelOverride: Bool
    let supportsEnvironmentOverrides: Bool
    let supportsCustomAgentName: Bool
}
