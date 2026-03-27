import Foundation

enum ACPProviderValidationStatus: String, Codable, Equatable, Sendable {
    case unknown
    case ready
    case failed
}

struct ACPProviderValidationSnapshot: Codable, Equatable, Sendable {
    var agentInfo: ACPImplementation?
    var agentCapabilities: ACPAgentCapabilities?
    var authMethods: [ACPAuthMethod]
    var status: ACPProviderValidationStatus
    var message: String
    var resolvedExecutablePath: String
    var verifiedAt: Date?

    init(
        agentInfo: ACPImplementation? = nil,
        agentCapabilities: ACPAgentCapabilities? = nil,
        authMethods: [ACPAuthMethod] = [],
        status: ACPProviderValidationStatus = .unknown,
        message: String = "",
        resolvedExecutablePath: String = "",
        verifiedAt: Date? = nil
    ) {
        self.agentInfo = agentInfo
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
        self.status = status
        self.message = message
        self.resolvedExecutablePath = resolvedExecutablePath
        self.verifiedAt = verifiedAt
    }
}