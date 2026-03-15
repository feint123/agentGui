import Foundation

enum LSPServerDefinitionSourceKind: String, Codable, Hashable, Sendable {
    case builtIn
    case installed
    case custom
}

struct LSPServerDefinition: Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let launchCommand: String
    let launchArguments: [String]
    let supportedLanguageIDs: [String]
    let defaultFileGlobs: [String]
    let rootMarkers: [String]
    let transportKind: LSPTransportKind
    let capabilityHints: LSPServerCapabilityHints
    let adapterKind: LSPAdapterKind
    let healthCheckMode: LSPHealthCheckMode
    let providerID: String
    let sourceKind: LSPServerDefinitionSourceKind

    init(
        id: String,
        displayName: String,
        launchCommand: String,
        launchArguments: [String],
        supportedLanguageIDs: [String],
        defaultFileGlobs: [String],
        rootMarkers: [String],
        transportKind: LSPTransportKind = .stdio,
        capabilityHints: LSPServerCapabilityHints = .readOnlySemanticDefaults,
        adapterKind: LSPAdapterKind,
        healthCheckMode: LSPHealthCheckMode = .initializeHandshake,
        providerID: String? = nil,
        sourceKind: LSPServerDefinitionSourceKind = .custom
    ) {
        self.id = id
        self.displayName = displayName
        self.launchCommand = launchCommand
        self.launchArguments = launchArguments
        self.supportedLanguageIDs = supportedLanguageIDs
        self.defaultFileGlobs = defaultFileGlobs
        self.rootMarkers = rootMarkers
        self.transportKind = transportKind
        self.capabilityHints = capabilityHints
        self.adapterKind = adapterKind
        self.healthCheckMode = healthCheckMode
        self.providerID = providerID ?? id
        self.sourceKind = sourceKind
    }

    func replacingLaunchCommand(_ launchCommand: String) -> LSPServerDefinition {
        LSPServerDefinition(
            id: id,
            displayName: displayName,
            launchCommand: launchCommand,
            launchArguments: launchArguments,
            supportedLanguageIDs: supportedLanguageIDs,
            defaultFileGlobs: defaultFileGlobs,
            rootMarkers: rootMarkers,
            transportKind: transportKind,
            capabilityHints: capabilityHints,
            adapterKind: adapterKind,
            healthCheckMode: healthCheckMode,
            providerID: providerID,
            sourceKind: sourceKind
        )
    }
}
