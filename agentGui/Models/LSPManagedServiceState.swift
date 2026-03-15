import Foundation

enum LSPInstallationState: String, Codable, Hashable, Sendable {
    case notInstalled
    case installed
    case failed
}

enum LSPConfigurationState: String, Codable, Hashable, Sendable {
    case notConfigured
    case configured
    case invalid
}

struct LSPManagedServiceState: Equatable, Sendable {
    let providerID: String
    let displayName: String
    let installationState: LSPInstallationState
    let configurationState: LSPConfigurationState
    let runtimeStateSummary: String
    let executablePath: String?
    let lastError: String?

    init(
        providerID: String,
        displayName: String,
        installationState: LSPInstallationState,
        configurationState: LSPConfigurationState,
        runtimeStateSummary: String,
        executablePath: String? = nil,
        lastError: String? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.installationState = installationState
        self.configurationState = configurationState
        self.runtimeStateSummary = runtimeStateSummary
        self.executablePath = executablePath
        self.lastError = lastError
    }
}