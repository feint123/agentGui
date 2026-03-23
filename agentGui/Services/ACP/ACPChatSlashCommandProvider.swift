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
                id: "acp:\(command.providerID.rawValue):\(command.name)",
                kind: .agent,
                title: command.name,
                subtitle: command.description ?? command.inputHint ?? "ACP command",
                aliases: ["/\(command.name)"],
                badge: command.providerID.displayName,
                isEnabledByDefault: true,
                payload: .acpCommand(
                    name: command.name,
                    argumentHint: command.inputHint,
                    providerID: command.providerID,
                    source: command.source
                )
            )
        }
    }
}