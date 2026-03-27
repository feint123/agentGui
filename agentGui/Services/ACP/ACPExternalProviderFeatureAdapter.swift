import Foundation

struct ACPExternalProviderFeatureAdapter {
    private let bootstrapper: @Sendable (ExecutionProviderReference, String, String) -> [ACPCommandDescriptor]

    init(
        bootstrapper: @escaping @Sendable (ExecutionProviderReference, String, String) -> [ACPCommandDescriptor] = { _, _, _ in [] }
    ) {
        self.bootstrapper = bootstrapper
    }

    func bootstrapEvents(
        providerReference: ExecutionProviderReference,
        providerDisplayName: String,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        let commands = bootstrapper(providerReference, providerDisplayName, remoteSessionID)
        guard !commands.isEmpty else { return [] }
        return [
            .replaceCommands(
                ACPCommandSnapshotDraft(
                    providerReference: providerReference,
                    remoteSessionID: remoteSessionID,
                    commands: commands
                )
            )
        ]
    }
}

extension ACPExternalProviderFeatureAdapter {
    static let openCode = ACPExternalProviderFeatureAdapter()

    static let gitHubCopilot = ACPExternalProviderFeatureAdapter()
}
