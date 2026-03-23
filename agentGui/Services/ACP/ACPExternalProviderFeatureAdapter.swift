import Foundation

struct ACPExternalProviderFeatureAdapter {
    private let bootstrapper: @Sendable (ConversationExecutionProviderID, String) -> [ACPCommandDescriptor]

    init(
        bootstrapper: @escaping @Sendable (ConversationExecutionProviderID, String) -> [ACPCommandDescriptor] = { _, _ in [] }
    ) {
        self.bootstrapper = bootstrapper
    }

    func bootstrapEvents(
        providerID: ConversationExecutionProviderID,
        remoteSessionID: String
    ) -> [ACPExternalSessionFeatureEvent] {
        let commands = bootstrapper(providerID, remoteSessionID)
        guard !commands.isEmpty else { return [] }
        return [
            .replaceCommands(
                ACPCommandSnapshotDraft(
                    providerID: providerID,
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
