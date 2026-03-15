import Foundation

@MainActor
final class LSPInstallCoordinator {
    private let catalog: LSPProviderCatalog
    private let strategies: [LSPInstallStrategy]
    private let commandRunner: LSPInstallCommandRunning
    private let fileSystem: LSPInstallFileManaging
    private let installRoot: URL
    private var activitiesByProviderID: [String: LSPInstallActivitySnapshot] = [:]

    var onStateDidChange: (() -> Void)?

    init(
        catalog: LSPProviderCatalog,
        strategies: [LSPInstallStrategy] = [.managedInstall],
        commandRunner: LSPInstallCommandRunning = LiveLSPInstallCommandRunner(),
        fileSystem: LSPInstallFileManaging = LiveLSPInstallFileSystem(),
        installRoot: URL = ConfigDirectoryManager.shared.lspServerDirectoryURL
    ) {
        self.catalog = catalog
        self.strategies = strategies
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.installRoot = installRoot
    }

    func activity(providerID: String) -> LSPInstallActivitySnapshot? {
        activitiesByProviderID[providerID]
    }

    func install(providerID: String) async -> LSPInstallResult {
        guard let provider = catalog.provider(id: providerID) else {
            let result = LSPInstallResult(
                providerID: providerID,
                status: .failed,
                message: "未知 provider",
                recoverySuggestion: .configureManually
            )
            recordFailure(providerID: providerID, message: result.message)
            return result
        }

        updateActivity(providerID: provider.id) { snapshot in
            LSPInstallActivitySnapshot(
                providerID: provider.id,
                phase: .preparing,
                progressMessage: "准备安装",
                detectedVersion: snapshot?.detectedVersion,
                lastFailure: nil,
                logs: snapshot?.logs ?? []
            )
        }

        var lastFailureResult: LSPInstallResult?

        for strategy in strategies {
            let result = await strategy.execute(
                provider: provider,
                commandRunner: commandRunner,
                fileSystem: fileSystem,
                installRoot: installRoot,
                report: { [weak self] event in
                    await self?.consume(event, providerID: provider.id)
                }
            )
            if result.status == .installed || result.status == .unchanged {
                updateActivity(providerID: provider.id) { snapshot in
                    LSPInstallActivitySnapshot(
                        providerID: provider.id,
                        phase: .completed,
                        progressMessage: "安装完成",
                        detectedVersion: result.installedProviderRecord?.version ?? snapshot?.detectedVersion,
                        lastFailure: nil,
                        logs: snapshot?.logs ?? []
                    )
                }
                return result
            }

            lastFailureResult = result
        }

        if let lastFailureResult {
            return lastFailureResult
        }

        let result = LSPInstallResult(
            providerID: provider.id,
            status: .failed,
            message: "未能完成安装或探测",
            recoverySuggestion: .recheckPath
        )
        recordFailure(providerID: provider.id, message: result.message)
        return result
    }

    func recheck(providerID: String) async -> LSPInstallResult {
        await install(providerID: providerID)
    }

    func repair(providerID: String) async -> LSPInstallResult {
        await install(providerID: providerID)
    }

    private func consume(_ event: LSPInstallActivityEvent, providerID: String) {
        updateActivity(providerID: providerID) { snapshot in
            var logs = snapshot?.logs ?? []
            if let logMessage = event.logMessage, !logMessage.isEmpty {
                logs.append(LSPInstallLogEntry(level: event.logLevel, message: logMessage))
                if logs.count > 40 {
                    logs.removeFirst(logs.count - 40)
                }
            }

            return LSPInstallActivitySnapshot(
                providerID: providerID,
                phase: event.phase ?? snapshot?.phase ?? .idle,
                progressMessage: event.progressMessage ?? snapshot?.progressMessage,
                detectedVersion: event.detectedVersion ?? snapshot?.detectedVersion,
                lastFailure: event.failureMessage ?? snapshot?.lastFailure,
                logs: logs
            )
        }
    }

    private func recordFailure(providerID: String, message: String) {
        updateActivity(providerID: providerID) { snapshot in
            var logs = snapshot?.logs ?? []
            logs.append(LSPInstallLogEntry(level: .error, message: message))
            if logs.count > 40 {
                logs.removeFirst(logs.count - 40)
            }

            return LSPInstallActivitySnapshot(
                providerID: providerID,
                phase: .failed,
                progressMessage: "安装失败",
                detectedVersion: snapshot?.detectedVersion,
                lastFailure: message,
                logs: logs
            )
        }
    }

    private func updateActivity(
        providerID: String,
        transform: (LSPInstallActivitySnapshot?) -> LSPInstallActivitySnapshot
    ) {
        activitiesByProviderID[providerID] = transform(activitiesByProviderID[providerID])
        onStateDidChange?()
    }
}