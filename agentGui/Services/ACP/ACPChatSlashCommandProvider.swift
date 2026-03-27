import Foundation

@MainActor
protocol ACPChatSlashCommandSource {
    func remoteCommands(localSessionID: String) -> [ACPCommandDescriptor]
}

extension ACPExternalExecutionProviderBase: ACPChatSlashCommandSource {}

struct ACPChatSlashCommandProvider: ChatSlashCommandProvider {
    let commands: [ACPCommandDescriptor]

    func items() -> [ChatSlashCommandItem] {
        commands.map { command in
            ChatSlashCommandItem(
                id: "acp:\(command.providerReference.persistedValue):\(command.name)",
                kind: .agent,
                title: command.name,
                subtitle: command.description ?? command.inputHint ?? "ACP command",
                aliases: ["/\(command.name)"],
                badge: command.providerDisplayName,
                isEnabledByDefault: true,
                payload: .acpCommand(
                    name: command.name,
                    argumentHint: command.inputHint,
                    providerReference: command.providerReference,
                    providerDisplayName: command.providerDisplayName,
                    source: command.source
                )
            )
        }
    }
}