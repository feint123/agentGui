import Foundation

struct ConversationAuthorizationPolicyFactory {
    nonisolated init() {}

    nonisolated func makePolicy(
        from settings: AppSettings,
        approvalMode: ToolApprovalMode = .none
    ) -> ToolAuthorizationPolicy {
        var levels = Dictionary(uniqueKeysWithValues: ToolCapabilityID.allCases.map { ($0, ToolCapabilityLevel.disabled) })

        if settings.enableTextEditorTool {
            levels[.fileSystem] = .mutate
        }
        if settings.enableBashTool {
            levels[.shell] = .execute
        }
        if settings.enableWebSearchTool || settings.enableWebFetchTool || settings.enableOllamaWebSearch {
            levels[.network] = .observe
        }
        if settings.memoryEnabled {
            levels[.memory] = .mutate
        }
        if settings.enableLSPTools {
            levels[.lsp] = .observe
        }

        return ToolAuthorizationPolicy(
            preset: .custom,
            capabilityLevels: levels,
            approvalMode: approvalMode
        )
    }
}