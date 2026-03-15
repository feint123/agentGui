import Foundation

enum LSPInstallStatus: String, Codable, Hashable, Sendable {
    case installed
    case failed
    case unchanged
}

enum LSPRecoverySuggestion: String, Codable, Hashable, Sendable {
    case recheckPath
    case installCommand
    case configureManually
    case none
}

enum LSPInstallPhase: String, Codable, Hashable, Sendable {
    case idle
    case preparing
    case installing
    case probingVersion
    case completed
    case failed

    var isRunning: Bool {
        switch self {
        case .preparing, .installing, .probingVersion:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}

enum LSPInstallLogLevel: String, Codable, Hashable, Sendable {
    case info
    case error
}

struct LSPInstallLogEntry: Codable, Hashable, Sendable {
    let timestamp: Date
    let level: LSPInstallLogLevel
    let message: String

    init(timestamp: Date = Date(), level: LSPInstallLogLevel, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }
}

struct LSPInstallActivitySnapshot: Equatable, Sendable {
    let providerID: String
    let phase: LSPInstallPhase
    let progressMessage: String?
    let detectedVersion: String?
    let lastFailure: String?
    let logs: [LSPInstallLogEntry]

    init(
        providerID: String,
        phase: LSPInstallPhase = .idle,
        progressMessage: String? = nil,
        detectedVersion: String? = nil,
        lastFailure: String? = nil,
        logs: [LSPInstallLogEntry] = []
    ) {
        self.providerID = providerID
        self.phase = phase
        self.progressMessage = progressMessage
        self.detectedVersion = detectedVersion
        self.lastFailure = lastFailure
        self.logs = logs
    }

    var isRunning: Bool {
        phase.isRunning
    }
}

struct LSPInstalledProviderRecord: Codable, Hashable, Sendable {
    let providerID: String
    let executablePath: String?
    let version: String?
    let installedAt: Date?

    init(
        providerID: String,
        executablePath: String? = nil,
        version: String? = nil,
        installedAt: Date? = nil
    ) {
        self.providerID = providerID
        self.executablePath = executablePath
        self.version = version
        self.installedAt = installedAt
    }
}

struct LSPInstallResult: Equatable, Sendable {
    let providerID: String
    let status: LSPInstallStatus
    let message: String
    let recoverySuggestion: LSPRecoverySuggestion
    let executablePath: String?
    let installedDefinition: LSPServerDefinition?
    let installedProviderRecord: LSPInstalledProviderRecord?

    init(
        providerID: String,
        status: LSPInstallStatus,
        message: String,
        recoverySuggestion: LSPRecoverySuggestion,
        executablePath: String? = nil,
        installedDefinition: LSPServerDefinition? = nil,
        installedProviderRecord: LSPInstalledProviderRecord? = nil
    ) {
        self.providerID = providerID
        self.status = status
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.executablePath = executablePath
        self.installedDefinition = installedDefinition
        self.installedProviderRecord = installedProviderRecord
    }
}