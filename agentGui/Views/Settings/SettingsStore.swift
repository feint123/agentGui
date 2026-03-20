import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private static var lastSelectedItem: SettingsNavigationItem = .defaultItem

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let persistenceCoordinator: PersistenceCoordinator?
    @ObservationIgnored private let gitHubCopilotCLIAvailabilityService: GitHubCopilotCLIAvailabilityService

    var settings: AppSettings
    var gitHubCopilotCLIAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus
    var selectedItem: SettingsNavigationItem {
        didSet {
            Self.lastSelectedItem = selectedItem
        }
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?,
        gitHubCopilotCLIAvailabilityService: GitHubCopilotCLIAvailabilityService = GitHubCopilotCLIAvailabilityService()
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.gitHubCopilotCLIAvailabilityService = gitHubCopilotCLIAvailabilityService
        self.settings = AppSettings.getOrCreate(
            in: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
        self.gitHubCopilotCLIAvailabilityStatus = .unknown
        self.selectedItem = Self.lastSelectedItem
    }

    @discardableResult
    func persistSettingsMutation(_ userMessage: String, mutation: () -> Void) -> Bool {
        mutation()
        do {
            if let persistenceCoordinator {
                try persistenceCoordinator.save(modelContext, domain: .settings, userMessage: userMessage)
            } else {
                try modelContext.save()
            }
            return true
        } catch {
            return false
        }
    }

    func persistedSettingsBinding<Value>(
        get: @escaping () -> Value,
        userMessage: String,
        set: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { newValue in
                _ = self.persistSettingsMutation(userMessage) {
                    set(newValue)
                }
            }
        )
    }

    func persistedGitHubCopilotCLIConfigurationBinding<Value>(
        get: @escaping (GitHubCopilotCLIConfiguration) -> Value,
        userMessage: String,
        set: @escaping (inout GitHubCopilotCLIConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: {
                get(self.settings.githubCopilotCLIConfiguration)
            },
            set: { newValue in
                _ = self.persistSettingsMutation(userMessage) {
                    var configuration = self.settings.githubCopilotCLIConfiguration
                    set(&configuration, newValue)
                    self.settings.githubCopilotCLIConfiguration = configuration
                }
            }
        )
    }

    func refreshGitHubCopilotCLIAvailabilityStatus() async {
        do {
            gitHubCopilotCLIAvailabilityStatus = try await gitHubCopilotCLIAvailabilityService.checkStatus(
                configuration: settings.githubCopilotCLIConfiguration
            )
        } catch {
            gitHubCopilotCLIAvailabilityStatus = GitHubCopilotCLIAvailabilityStatus(
                kind: .failed(error.localizedDescription),
                version: nil
            )
        }
    }

    static func resetSelectionMemoryForTesting() {
        lastSelectedItem = .defaultItem
    }
}