import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private static var lastSelectedItem: SettingsNavigationItem = .defaultItem

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let persistenceCoordinator: PersistenceCoordinator?
    @ObservationIgnored private let providerProfileRepository: ACPProviderProfileRepository
    @ObservationIgnored private let providerValidationService: ACPProviderValidationService

    var settings: AppSettings
    var acpProviderProfiles: [ACPProviderProfile]
    var selectedItem: SettingsNavigationItem {
        didSet {
            Self.lastSelectedItem = selectedItem
        }
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?,
        providerValidationService: ACPProviderValidationService = ACPProviderValidationService()
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.providerProfileRepository = ACPProviderProfileRepository(modelContext: modelContext)
        self.providerValidationService = providerValidationService
        self.settings = AppSettings.getOrCreate(
            in: modelContext,
            persistenceCoordinator: persistenceCoordinator
        )
        self.acpProviderProfiles = (try? self.providerProfileRepository.allProfiles()) ?? []
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

    func reloadACPProviderProfiles() throws {
        acpProviderProfiles = try providerProfileRepository.allProfiles()
        reconcileDefaultExecutionProviderSelection()
    }

    func reloadACPProviderProfiles(refreshing claudeService: ClaudeService) throws {
        try reloadACPProviderProfiles()
        claudeService.refreshExecutionProviderRuntime(for: modelContext)
    }

    func defaultExecutionProviderOptions() -> [ExecutionOptionItem] {
        [
            ExecutionOptionItem(
                id: ExecutionProviderReference.builtIn.persistedValue,
                title: ConversationExecutionProviderID.builtInAgent.displayName
            )
        ] + acpProviderProfiles
            .filter(\ .isEnabled)
            .map {
                ExecutionOptionItem(
                    id: ExecutionProviderReference.externalACP(profileID: $0.id).persistedValue,
                    title: $0.displayName
                )
            }
    }

    func defaultExecutionProviderSelectionBinding() -> Binding<String> {
        Binding(
            get: { self.settings.defaultExecutionProviderReference.persistedValue },
            set: { newValue in
                _ = self.persistSettingsMutation("默认执行器设置未成功保存") {
                    self.settings.defaultExecutionProviderReference = self.validatedProviderSelection(for: newValue)
                }
            }
        )
    }

    func makeACPProviderEditorViewModel(profileID: UUID? = nil) -> ACPProviderSettingsEditorViewModel {
        let profile = acpProviderProfiles.first(where: { $0.id == profileID })
        return ACPProviderSettingsEditorViewModel(
            profile: profile,
            repository: providerProfileRepository,
            validationService: providerValidationService
        )
    }

    @discardableResult
    func deleteACPProvider(profileID: UUID) -> Bool {
        guard let profile = acpProviderProfiles.first(where: { $0.id == profileID }),
                            canDeleteACPProvider(profile) else {
            return false
        }

        do {
            try providerProfileRepository.delete(profileID: profileID)
            try reloadACPProviderProfiles()
            return true
        } catch {
            return false
        }
    }

    func canDeleteACPProvider(_ profile: ACPProviderProfile) -> Bool {
        profile.sourceKind != .preset && !isProviderProfileReferenced(profile.id)
    }

    static func resetSelectionMemoryForTesting() {
        lastSelectedItem = .defaultItem
    }

    private func reconcileDefaultExecutionProviderSelection() {
        let currentReference = settings.defaultExecutionProviderReference
        guard case let .externalACP(profileID) = currentReference else {
            return
        }

        let isEnabled = acpProviderProfiles.contains(where: { $0.id == profileID && $0.isEnabled })
        guard !isEnabled else {
            return
        }

        _ = persistSettingsMutation("默认执行器设置未成功保存") {
            settings.defaultExecutionProviderReference = .builtIn
        }
    }

    private func validatedProviderSelection(for persistedValue: String) -> ExecutionProviderReference {
        let reference = ExecutionProviderReference.decodePersisted(persistedValue)
        switch reference {
        case .builtIn:
            return .builtIn
        case let .externalACP(profileID):
            let isEnabled = acpProviderProfiles.contains { $0.id == profileID && $0.isEnabled }
            return isEnabled ? reference : .builtIn
        }
    }

    private func isProviderProfileReferenced(_ profileID: UUID) -> Bool {
        if settings.defaultExecutionProviderReference == .externalACP(profileID: profileID) {
            return true
        }

        let descriptor = FetchDescriptor<Session>()
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        return sessions.contains { $0.defaultExecutionProviderReference == .externalACP(profileID: profileID) }
    }
}