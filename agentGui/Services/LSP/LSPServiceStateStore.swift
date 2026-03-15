import Foundation

@MainActor
struct LSPServiceStateStore {
    let catalog: LSPProviderCatalog
    let serverManager: LSPServerManager?

    func states(
        settings: AppSettings,
        workingDirectory: String,
        selectedFilePath: String?
    ) -> [LSPManagedServiceState] {
        catalog.allProviders().map { provider in
            state(
                providerID: provider.id,
                settings: settings,
                workingDirectory: workingDirectory,
                selectedFilePath: selectedFilePath
            )
        }
    }

    func state(
        providerID: String,
        settings: AppSettings,
        workingDirectory: String,
        selectedFilePath: String?
    ) -> LSPManagedServiceState {
        guard let provider = catalog.provider(id: providerID) else {
            return LSPManagedServiceState(
                providerID: providerID,
                displayName: providerID,
                installationState: .notInstalled,
                configurationState: .notConfigured,
                runtimeStateSummary: "未知服务"
            )
        }

        let installationRecord = settings.lspInstalledProviders.first { $0.providerID == provider.id }
        let configuredDefinition = configuredDefinition(for: provider, settings: settings)
        let runtimeState = resolvedRuntimeState(
            provider: provider,
            configuredDefinition: configuredDefinition,
            workingDirectory: workingDirectory
        )

        let installationState: LSPInstallationState = {
            if provider.isBuiltIn || installationRecord != nil || configuredDefinition?.sourceKind == .installed {
                return .installed
            }
            return .notInstalled
        }()

        let configurationState: LSPConfigurationState = configuredDefinition == nil ? .notConfigured : .configured
        let executablePath = installationRecord?.executablePath ?? configuredExecutablePath(for: configuredDefinition)
        let lastError = runtimeErrorMessage(for: runtimeState)

        return LSPManagedServiceState(
            providerID: provider.id,
            displayName: provider.displayName,
            installationState: installationState,
            configurationState: configurationState,
            runtimeStateSummary: runtimeSummary(
                runtimeState: runtimeState,
                installationState: installationState,
                configurationState: configurationState,
                selectedFilePath: selectedFilePath,
                provider: provider
            ),
            executablePath: executablePath,
            lastError: lastError
        )
    }

    private func configuredDefinition(
        for provider: LSPProviderDefinition,
        settings: AppSettings
    ) -> LSPServerDefinition? {
        if let installed = settings.lspInstalledServerDefinitions.first(where: { $0.providerID == provider.id || $0.id == provider.id }) {
            return installed
        }

        if let custom = settings.lspCustomServerProfiles.first(where: { $0.providerID == provider.id || $0.id == provider.id }) {
            return custom
        }

        return provider.isBuiltIn ? provider.defaultServerTemplate : nil
    }

    private func resolvedRuntimeState(
        provider: LSPProviderDefinition,
        configuredDefinition: LSPServerDefinition?,
        workingDirectory: String
    ) -> LSPProcessState? {
        guard !workingDirectory.isEmpty,
              let configuredDefinition else {
            return nil
        }

        return serverManager?.state(for: workingDirectory, serverID: configuredDefinition.id)
    }

    private func configuredExecutablePath(for definition: LSPServerDefinition?) -> String? {
        guard let definition,
              definition.launchCommand.contains("/") else {
            return nil
        }
        return definition.launchCommand
    }

    private func runtimeSummary(
        runtimeState: LSPProcessState?,
        installationState: LSPInstallationState,
        configurationState: LSPConfigurationState,
        selectedFilePath: String?,
        provider: LSPProviderDefinition
    ) -> String {
        if let runtimeState {
            switch runtimeState {
            case .running:
                return "运行中"
            case .starting:
                return "启动中"
            case .failedToLaunch:
                return "启动失败"
            case .crashed:
                return "运行崩溃"
            case .stopped:
                return "已停止"
            case .idle:
                return "未启动"
            }
        }

        if let selectedFilePath,
           let matched = catalog.providerForFilePath(selectedFilePath),
           matched.id == provider.id,
           installationState == .notInstalled {
            return "未安装"
        }

        switch (installationState, configurationState) {
        case (.notInstalled, _):
            return "未安装"
        case (.failed, _):
            return "安装失败"
        case (.installed, .notConfigured):
            return "未配置"
        case (.installed, .configured):
            return "未启动"
        case (_, .invalid):
            return "配置异常"
        }
    }

    private func runtimeErrorMessage(for runtimeState: LSPProcessState?) -> String? {
        guard let runtimeState else { return nil }
        switch runtimeState {
        case .failedToLaunch(let reason):
            return reason
        case .crashed(let reason, _):
            return reason
        default:
            return nil
        }
    }
}