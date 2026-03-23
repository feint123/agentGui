import Foundation

@MainActor
protocol ACPExternalProviderRuntimeClient: AnyObject {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake
    func setModel(_ modelID: String, sessionID: String) async throws
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

@MainActor
protocol ACPExternalProviderRuntimeTransportClient: AnyObject {
    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot
    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake?
    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake
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

struct SessionRuntimeKey: Hashable, Sendable {
    let providerID: ConversationExecutionProviderID
    let localSessionID: String
}

struct RuntimeActivationID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ACPSessionRuntimePhase: String, Equatable, Sendable {
    case idle
    case startingRuntime
    case initializing
    case restoring
    case ready
    case sendingTurn
    case cancelling
    case closing
    case closed
}
