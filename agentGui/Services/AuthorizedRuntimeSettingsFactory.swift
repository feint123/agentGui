import Foundation

struct AuthorizedRuntimeSettingsFactory {
    func makeRuntimeSettings(
        base: AppSettings,
        snapshot: EffectiveToolAuthorizationSnapshot,
        workingDirectory: String? = nil,
        enabledSkillNames: [String]? = nil,
        autoStartLSPServers: Bool? = nil
    ) -> AppSettings {
        let runtimeSettings = AppSettings()
        runtimeSettings.apiKey = base.apiKey
        runtimeSettings.baseURL = base.baseURL
        runtimeSettings.selectedModel = base.selectedModel
        runtimeSettings.defaultExecutionProviderID = base.defaultExecutionProviderID
        runtimeSettings.themeMode = base.themeMode
        runtimeSettings.messageFontSize = base.messageFontSize
        runtimeSettings.enableTextEditorTool = snapshot.allowedToolIDs.contains("str_replace_based_edit_tool")
        runtimeSettings.enableBashTool = snapshot.allowedToolIDs.contains("bash")
        runtimeSettings.workingDirectory = workingDirectory ?? base.workingDirectory
        runtimeSettings.enableExtendedThinking = base.enableExtendedThinking
        runtimeSettings.extendedThinkingBudget = base.extendedThinkingBudget
        runtimeSettings.enabledSkillNames = enabledSkillNames ?? base.enabledSkillNames
        runtimeSettings.githubCopilotCLIConfiguration = base.githubCopilotCLIConfiguration
        runtimeSettings.openCodeCLIConfiguration = base.openCodeCLIConfiguration
        runtimeSettings.claudeAdapterCLIConfiguration = base.claudeAdapterCLIConfiguration
        runtimeSettings.enableWebSearchTool = snapshot.allowedToolIDs.contains("web_search")
        runtimeSettings.enableWebFetchTool = snapshot.allowedToolIDs.contains("web_fetch")
        runtimeSettings.enableLSPTools = snapshot.allowedToolIDs.contains(where: { $0.hasPrefix("lsp_") })
        runtimeSettings.autoStartLSPServers = autoStartLSPServers ?? base.autoStartLSPServers
        runtimeSettings.lspDefaultRoutingMode = base.lspDefaultRoutingMode
        runtimeSettings.lspCustomServerProfiles = base.lspCustomServerProfiles
        runtimeSettings.lspInstalledProviders = base.lspInstalledProviders
        runtimeSettings.lspInstalledServerDefinitions = base.lspInstalledServerDefinitions
        runtimeSettings.lspManualWorkspaceBindingsJSON = base.lspManualWorkspaceBindingsJSON
        runtimeSettings.ollamaAPIKey = base.ollamaAPIKey
        runtimeSettings.enableOllamaWebSearch = base.enableOllamaWebSearch && snapshot.level(for: .network) >= .observe
        runtimeSettings.enableNetworkProxy = base.enableNetworkProxy
        runtimeSettings.networkProxyURL = base.networkProxyURL
        runtimeSettings.networkProxyBypassList = base.networkProxyBypassList
        runtimeSettings.memoryEnabled = base.memoryEnabled && snapshot.level(for: .memory) >= .mutate
        runtimeSettings.memoryContextBudget = base.memoryContextBudget
        runtimeSettings.backgroundAgentEnabled = base.backgroundAgentEnabled
        runtimeSettings.backgroundAgentDefaultQoS = base.backgroundAgentDefaultQoS
        runtimeSettings.backgroundAgentRequiresExternalPower = base.backgroundAgentRequiresExternalPower
        runtimeSettings.backgroundAgentAllowNetworkTools = base.backgroundAgentAllowNetworkTools
        runtimeSettings.backgroundAgentMaximumConcurrentRuns = base.backgroundAgentMaximumConcurrentRuns
        runtimeSettings.backgroundAgentObservationRetentionDays = base.backgroundAgentObservationRetentionDays
        return runtimeSettings
    }
}
