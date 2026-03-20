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
    @ObservationIgnored private let openCodeCLIAvailabilityService: OpenCodeCLIAvailabilityService

    var settings: AppSettings
    var gitHubCopilotCLIAvailabilityStatus: GitHubCopilotCLIAvailabilityStatus
    var openCodeCLIAvailabilityStatus: OpenCodeCLIAvailabilityStatus
    var selectedItem: SettingsNavigationItem {
        didSet {
            Self.lastSelectedItem = selectedItem
        }
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?,
        gitHubCopilotCLIAvailabilityService: GitHubCopilotCLIAvailabilityService = GitHubCopilotCLIAvailabilityService(),
        openCodeCLIAvailabilityService: OpenCodeCLIAvailabilityService = OpenCodeCLIAvailabilityService()
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.gitHubCopilotCLIAvailabilityService = gitHubCopilotCLIAvailabilityService
        self.openCodeCLIAvailabilityService = openCodeCLIAvailabilityService
        self.settings = AppSettings.getOrCreate(
            in: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
        self.gitHubCopilotCLIAvailabilityStatus = .unknown
        self.openCodeCLIAvailabilityStatus = .unknown
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
        get: @escaping @Sendable () -> Value,
        userMessage: String,
        set: @escaping @Sendable (Value) -> Void
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
        get: @escaping @Sendable (GitHubCopilotCLIConfiguration) -> Value,
        userMessage: String,
        set: @escaping @Sendable (inout GitHubCopilotCLIConfiguration, Value) -> Void
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

    func persistedOpenCodeCLIConfigurationBinding<Value>(
        get: @escaping @Sendable (OpenCodeCLIConfiguration) -> Value,
        userMessage: String,
        set: @escaping @Sendable (inout OpenCodeCLIConfiguration, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: {
                get(self.settings.openCodeCLIConfiguration)
            },
            set: { newValue in
                _ = self.persistSettingsMutation(userMessage) {
                    var configuration = self.settings.openCodeCLIConfiguration
                    set(&configuration, newValue)
                    self.settings.openCodeCLIConfiguration = configuration
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

    func refreshOpenCodeCLIAvailabilityStatus() async {
        do {
            openCodeCLIAvailabilityStatus = try await openCodeCLIAvailabilityService.checkStatus(
                configuration: settings.openCodeCLIConfiguration
            )
        } catch {
            openCodeCLIAvailabilityStatus = OpenCodeCLIAvailabilityStatus(
                kind: .failed(error.localizedDescription),
                version: nil,
                displayName: "OpenCode"
            )
        }
    }

    static func resetSelectionMemoryForTesting() {
        lastSelectedItem = .defaultItem
    }
}