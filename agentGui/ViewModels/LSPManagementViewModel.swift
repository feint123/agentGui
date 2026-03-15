import Foundation

enum LSPManagementAction: Hashable, Sendable {
    case install
    case recheck
    case start
    case stop
    case restart
    case repair
}

struct LSPServicePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let languagesText: String
    let installStatusText: String
    let installActivityText: String?
    let runtimeStatusText: String
    let versionText: String?
    let executablePath: String?
    let detailText: String?
    let installLogLines: [String]
    let isInstallInProgress: Bool
    let availableActions: [LSPManagementAction]
}

@MainActor
struct LSPManagementViewModel {
    let settings: AppSettings
    let serviceStateStore: LSPServiceStateStore
    let installCoordinator: LSPInstallCoordinator
    let serverManager: LSPServerManager?
    let persistSettings: (_ userMessage: String, _ mutation: () -> Void) -> Bool

    var services: [LSPServicePresentation] {
        let states = serviceStateStore.states(
            settings: settings,
            workingDirectory: settings.workingDirectory,
            selectedFilePath: nil
        )

        return states.compactMap { state in
            guard let provider = serviceStateStore.catalog.provider(id: state.providerID) else {
                return nil
            }
            let activity = installCoordinator.activity(providerID: provider.id)
            let installedRecord = settings.lspInstalledProviders.first { $0.providerID == provider.id }
            return LSPServicePresentation(
                id: provider.id,
                title: provider.displayName,
                languagesText: provider.supportedLanguageIDs.joined(separator: ", "),
                installStatusText: installStatusText(for: state.installationState, activity: activity),
                installActivityText: activity?.progressMessage,
                runtimeStatusText: state.runtimeStateSummary,
                versionText: activity?.detectedVersion ?? installedRecord?.version,
                executablePath: state.executablePath,
                detailText: activity?.lastFailure ?? state.lastError,
                installLogLines: activity?.logs.map(\.message) ?? [],
                isInstallInProgress: activity?.isRunning == true,
                availableActions: availableActions(for: state, activity: activity)
            )
        }
    }

    func perform(_ action: LSPManagementAction, for providerID: String) async throws {
        guard let provider = serviceStateStore.catalog.provider(id: providerID) else {
            return
        }

        switch action {
        case .install:
            let result = await installCoordinator.install(providerID: providerID)
            persistInstallResult(result)

        case .recheck:
            let result = await installCoordinator.recheck(providerID: providerID)
            persistInstallResult(result)

        case .repair:
            let result = await installCoordinator.repair(providerID: providerID)
            persistInstallResult(result)

        case .start:
            guard !settings.workingDirectory.isEmpty,
                  let serverID = configuredServerID(for: provider) else { return }
            _ = try await serverManager?.startSession(workspaceRoot: settings.workingDirectory, serverID: serverID)

        case .stop:
            guard !settings.workingDirectory.isEmpty,
                  let serverID = configuredServerID(for: provider) else { return }
            await serverManager?.stopSession(workspaceRoot: settings.workingDirectory, serverID: serverID)

        case .restart:
            guard !settings.workingDirectory.isEmpty,
                  let serverID = configuredServerID(for: provider) else { return }
            _ = try await serverManager?.restartServer(workspaceRoot: settings.workingDirectory, serverID: serverID)
        }
    }

    private func configuredServerID(for provider: LSPProviderDefinition) -> String? {
        if let installed = settings.lspInstalledServerDefinitions.first(where: { $0.providerID == provider.id || $0.id == provider.id }) {
            return installed.id
        }

        if let custom = settings.lspCustomServerProfiles.first(where: { $0.providerID == provider.id || $0.id == provider.id }) {
            return custom.id
        }

        return provider.isBuiltIn ? provider.defaultServerTemplate.id : nil
    }

    private func persistInstallResult(_ result: LSPInstallResult) {
        guard result.status == .installed else {
            return
        }

        _ = persistSettings("LSP 服务安装状态未成功保存") {
            if let record = result.installedProviderRecord {
                var records = settings.lspInstalledProviders.filter { $0.providerID != record.providerID }
                records.append(record)
                settings.lspInstalledProviders = records.sorted { $0.providerID < $1.providerID }
            }

            if let definition = result.installedDefinition {
                var definitions = settings.lspInstalledServerDefinitions.filter { $0.id != definition.id }
                definitions.append(definition)
                settings.lspInstalledServerDefinitions = definitions.sorted { $0.id < $1.id }
            }
        }
    }

    private func availableActions(for state: LSPManagedServiceState, activity: LSPInstallActivitySnapshot?) -> [LSPManagementAction] {
        if activity?.isRunning == true {
            return []
        }

        switch state.runtimeStateSummary {
        case "运行中":
            return [.stop, .restart, .recheck]
        case "启动失败", "运行崩溃":
            return [.repair, .restart, .recheck]
        case "未安装":
            return [.install, .recheck]
        default:
            if state.configurationState == .configured {
                return [.start, .recheck]
            }
            return [.install, .recheck]
        }
    }

    private func installStatusText(for state: LSPInstallationState, activity: LSPInstallActivitySnapshot?) -> String {
        if let activity {
            switch activity.phase {
            case .preparing:
                return "准备中"
            case .installing:
                return "安装中"
            case .probingVersion:
                return "探测版本"
            case .completed:
                return "已安装"
            case .failed:
                return "安装失败"
            case .idle:
                break
            }
        }

        switch state {
        case .installed:
            return "已安装"
        case .failed:
            return "安装失败"
        case .notInstalled:
            return "未安装"
        }
    }
}