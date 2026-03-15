import Foundation
import SwiftData

@MainActor
struct WorkspacePanelLSPFooterPresenter {
    let claudeService: ClaudeService
    let persistenceCoordinator: PersistenceCoordinator
    let modelContext: ModelContext

    func status(workingDirectory: String, selectedFilePath: String?) -> WorkspacePanelLSPStatusPresentation {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)
        return claudeService.makeWorkspacePanelLSPStatus(
            workingDirectory: workingDirectory,
            selectedFilePath: selectedFilePath,
            settings: settings
        )
    }

    func tone(for stateText: String) -> LSPStatusPresentationTone {
        LSPStatusPresentationTone.tone(for: stateText)
    }

    func managementViewModel(onPersistSettings: @escaping (String, () -> Void) -> Bool) -> LSPManagementViewModel {
        let settings = AppSettings.getOrCreate(in: modelContext, persistenceCoordinator: persistenceCoordinator)

        return LSPManagementViewModel(
            settings: settings,
            serviceStateStore: LSPServiceStateStore(
                catalog: .builtInCatalog(),
                serverManager: claudeService.lspServerManager
            ),
            installCoordinator: claudeService.lspInstallCoordinator,
            serverManager: claudeService.lspServerManager,
            persistSettings: { userMessage, mutation in
                onPersistSettings(userMessage, mutation)
            }
        )
    }
}