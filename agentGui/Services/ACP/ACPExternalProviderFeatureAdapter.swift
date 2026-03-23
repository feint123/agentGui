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
        return [.replaceCommands(commands)]
    }
}

extension ACPExternalProviderFeatureAdapter {
    static let openCode = ACPExternalProviderFeatureAdapter()

    static let gitHubCopilot = ACPExternalProviderFeatureAdapter { providerID, remoteSessionID in
        guard providerID == .githubCopilotCLI else { return [] }
        return [
            ACPCommandDescriptor(
                providerID: providerID,
                remoteSessionID: remoteSessionID,
                name: "plan",
                description: "Create a step-by-step implementation plan",
                inputHint: "what to plan",
                source: .documentedSeed
            ),
            ACPCommandDescriptor(
                providerID: providerID,
                remoteSessionID: remoteSessionID,
                name: "review",
                description: "Review code or changes",
                inputHint: "what to review",
                source: .documentedSeed
            ),
            ACPCommandDescriptor(
                providerID: providerID,
                remoteSessionID: remoteSessionID,
                name: "agent",
                description: "Delegate work to a specialized agent",
                inputHint: "task for the agent",
                source: .documentedSeed
            )
        ]
    }
}
