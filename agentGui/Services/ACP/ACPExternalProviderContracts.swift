import Foundation

protocol ACPExternalProviderRuntimeClient: AnyObject, Sendable {
    func ensureSession(workingDirectory: String, remoteSessionID: String?) async throws -> ACPExternalAgentSessionHandshake
    func setSessionMode(_ modeID: String, sessionID: String) async throws
    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption]
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

protocol ACPExternalProviderRuntimeTransportClient: AnyObject, Sendable {
    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot
    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake?
    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake
    func setSessionMode(_ modeID: String, sessionID: String) async throws
    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption]
    func prompt(text: String, sessionID: String) async throws -> ACPStopReason
    func cancel(sessionID: String) async throws
    func close() async
}

nonisolated struct ACPExternalSessionConfigSelection: Equatable, Sendable {
    let configID: String
    let value: String
    let category: ACPSessionConfigOptionCategory?
}

nonisolated struct SessionRuntimeKey: Hashable, Sendable {
    let providerID: ConversationExecutionProviderID
    let localSessionID: String
}

nonisolated struct RuntimeActivationID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum ACPSessionRuntimePhase: String, Equatable, Sendable {
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
