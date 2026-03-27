import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct SettingsExecutorsDynamicProviderTests {
    @Test
    func saveEnabledProfileValidatesBeforePersisting() async throws {
        let context = try makeModelContext()
        let repository = ACPProviderProfileRepository(modelContext: context)
        let probe = ValidationRuntimeProbe(
            response: ACPInitializeResponse(
                agentCapabilities: ACPAgentCapabilities(loadSession: true),
                agentInfo: ACPImplementation(name: "copilot", title: "GitHub Copilot", version: "1.0.0"),
                authMethods: [],
                protocolVersion: 1
            )
        )
        let viewModel = ACPProviderSettingsEditorViewModel(
            repository: repository,
            validationService: ACPProviderValidationService(
                executableResolver: { _ in URL(fileURLWithPath: "/usr/local/bin/copilot") },
                runtimeFactory: { configuration in
                    probe.record(configuration: configuration)
                    return TestValidationRuntime(response: probe.response)
                }
            )
        )
        viewModel.displayName = "GitHub Copilot"
        viewModel.executablePath = "copilot"
        viewModel.argumentsText = "acp\n--stdio"
        viewModel.isEnabled = true

        let saved = await viewModel.save()

        #expect(saved)
        let configuration = try #require(probe.configurations.first)
        #expect(configuration.command == "/usr/local/bin/copilot")
        #expect(configuration.arguments == ["acp", "--stdio"])

        let profiles = try repository.allProfiles()
        #expect(profiles.count == 1)
        #expect(profiles[0].validationSnapshot?.status == .ready)
        #expect(profiles[0].validationSnapshot?.resolvedExecutablePath == "/usr/local/bin/copilot")
        #expect(profiles[0].displayName == "GitHub Copilot")
    }

    @Test
    func saveEnabledProfileParsesSingleLineSpaceSeparatedArguments() async throws {
        let context = try makeModelContext()
        let repository = ACPProviderProfileRepository(modelContext: context)
        let probe = ValidationRuntimeProbe(
            response: ACPInitializeResponse(
                agentCapabilities: ACPAgentCapabilities(loadSession: true),
                agentInfo: ACPImplementation(name: "custom", title: "Custom Agent", version: "1.0.0"),
                authMethods: [],
                protocolVersion: 1
            )
        )
        let viewModel = ACPProviderSettingsEditorViewModel(
            repository: repository,
            validationService: ACPProviderValidationService(
                executableResolver: { _ in URL(fileURLWithPath: "/usr/local/bin/custom-agent") },
                runtimeFactory: { configuration in
                    probe.record(configuration: configuration)
                    return TestValidationRuntime(response: probe.response)
                }
            )
        )
        viewModel.displayName = "Custom Agent"
        viewModel.executablePath = "custom-agent"
        viewModel.argumentsText = "--mode fast --sandbox workspace"
        viewModel.isEnabled = true

        let saved = await viewModel.save()

        #expect(saved)
        let configuration = try #require(probe.configurations.first)
        #expect(configuration.arguments == ["--mode", "fast", "--sandbox", "workspace"])
        let profile = try #require(repository.allProfiles().first)
        #expect(profile.arguments == ["--mode", "fast", "--sandbox", "workspace"])
    }

    @Test
    func validationFailureKeepsDraftUnsavedAndExposesErrorMessage() async throws {
        let context = try makeModelContext()
        let repository = ACPProviderProfileRepository(modelContext: context)
        let viewModel = ACPProviderSettingsEditorViewModel(
            repository: repository,
            validationService: ACPProviderValidationService(
                executableResolver: { _ in nil },
                runtimeFactory: { _ in
                    Issue.record("runtimeFactory should not be called when executable is missing")
                    return TestValidationRuntime(response: nil)
                }
            )
        )
        viewModel.displayName = "OpenCode"
        viewModel.executablePath = "opencode"
        viewModel.isEnabled = true

        let saved = await viewModel.save()

        #expect(!saved)
        #expect(viewModel.errorMessage == "未找到 OpenCode 可执行文件：opencode")
        #expect(try repository.allProfiles().isEmpty)
    }

    @Test
    func successfulSavePersistsProviderProfileAndSnapshot() async throws {
        let context = try makeModelContext()
        let repository = ACPProviderProfileRepository(modelContext: context)
        let snapshot = ACPProviderValidationSnapshot(
            agentInfo: ACPImplementation(name: "claude-code", title: "Claude Code", version: "1.0.0"),
            agentCapabilities: ACPAgentCapabilities(
                loadSession: true,
                promptCapabilities: ACPPromptCapabilities(audio: true, embeddedContext: true, image: false),
                mcpCapabilities: ACPMcpCapabilities(http: true, sse: true),
                sessionCapabilities: ACPSessionCapabilities(list: ACPSessionListCapabilities(pageSize: 50))
            ),
            authMethods: [ACPAuthMethod(description: "Browser", id: "browser", name: "Browser")],
            status: .ready,
            message: "validated",
            resolvedExecutablePath: "/usr/local/bin/claude",
            verifiedAt: Date(timeIntervalSince1970: 4567)
        )
        let probe = ValidationRuntimeProbe(
            response: ACPInitializeResponse(
                agentCapabilities: snapshot.agentCapabilities,
                agentInfo: snapshot.agentInfo,
                authMethods: snapshot.authMethods,
                protocolVersion: 1
            )
        )
        let viewModel = ACPProviderSettingsEditorViewModel(
            repository: repository,
            validationService: ACPProviderValidationService(
                executableResolver: { _ in URL(fileURLWithPath: snapshot.resolvedExecutablePath) },
                runtimeFactory: { configuration in
                    probe.record(configuration: configuration)
                    return TestValidationRuntime(response: probe.response)
                }
            )
        )
        viewModel.displayName = "Claude Code"
        viewModel.executablePath = "claude"
        viewModel.argumentsText = "adapter\n--stdio"
        viewModel.isEnabled = true

        let saved = await viewModel.save()

        #expect(saved)
        let profile = try #require(repository.allProfiles().first)
        #expect(profile.displayName == "Claude Code")
        #expect(profile.executablePath == "claude")
        #expect(profile.arguments == ["adapter", "--stdio"])
        #expect(profile.validationSnapshot?.status == .ready)
        #expect(profile.validationSnapshot?.agentInfo?.name == snapshot.agentInfo?.name)
        #expect(profile.validationSnapshot?.resolvedExecutablePath == snapshot.resolvedExecutablePath)
        #expect(profile.validationSnapshot?.authMethods.map { $0.id } == snapshot.authMethods.map { $0.id })
        #expect(profile.validationSnapshot?.agentCapabilities == snapshot.agentCapabilities)
        #expect(viewModel.capabilityRows.map { $0.title } == [
            "会话恢复",
            "多模态 Prompt",
            "MCP 传输",
            "Session 列表"
        ])
        #expect(viewModel.capabilityRows.map { $0.value } == [
            "支持",
            "音频、嵌入上下文",
            "HTTP、SSE",
            "分页大小 50"
        ])
    }

    @Test
    func capabilityRowsAreEmptyWithoutValidationSnapshot() throws {
        let context = try makeModelContext()
        let repository = ACPProviderProfileRepository(modelContext: context)
        let viewModel = ACPProviderSettingsEditorViewModel(repository: repository)

        #expect(viewModel.capabilityRows.isEmpty)
    }

    @Test
    func defaultProviderPickerListsBuiltInPlusEnabledExternalProfiles() throws {
        let context = try makeModelContext()
        let store = SettingsStore(modelContext: context, persistenceCoordinator: nil)
        let repository = ACPProviderProfileRepository(modelContext: context)

        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                id: UUID(uuidString: "88888888-8888-8888-8888-888888888888"),
                displayName: "Enabled Provider",
                executablePath: "/usr/bin/enabled",
                isEnabled: true,
                sortOrder: 0,
                validationSnapshot: .init(status: .ready)
            )
        )
        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                id: UUID(uuidString: "99999999-9999-9999-9999-999999999999"),
                displayName: "Disabled Provider",
                executablePath: "/usr/bin/disabled",
                isEnabled: false,
                sortOrder: 1
            )
        )

        try store.reloadACPProviderProfiles()
        let options = store.defaultExecutionProviderOptions()

        #expect(options.map(\.title) == ["内置 Agent", "Enabled Provider"])
        #expect(options.map(\.id) == [
            ExecutionProviderReference.builtIn.persistedValue,
            ExecutionProviderReference.externalACP(profileID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!).persistedValue,
        ])
    }

    @Test
    func invalidDefaultProviderSelectionFallsBackToBuiltIn() throws {
        let context = try makeModelContext()
        let store = SettingsStore(modelContext: context, persistenceCoordinator: nil)

        store.defaultExecutionProviderSelectionBinding().wrappedValue = ExecutionProviderReference.externalACP(
            profileID: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        ).persistedValue

        #expect(store.settings.defaultExecutionProviderReference == .builtIn)
    }

    @Test
    func referencedProviderCannotBeDeleted() throws {
        let context = try makeModelContext()
        let store = SettingsStore(modelContext: context, persistenceCoordinator: nil)
        let repository = ACPProviderProfileRepository(modelContext: context)
        let profileID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!

        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                id: profileID,
                displayName: "Referenced Provider",
                executablePath: "/usr/bin/referenced",
                isEnabled: true,
                sortOrder: 0,
                validationSnapshot: .init(status: .ready)
            )
        )

        let session = Session.fixture(title: "Uses External")
        session.defaultExecutionProviderReference = .externalACP(profileID: profileID)
        context.insert(session)
        try context.save()

        try store.reloadACPProviderProfiles()
        let profile = try #require(store.acpProviderProfiles.first(where: { $0.id == profileID }))

        #expect(store.canDeleteACPProvider(profile) == false)
        #expect(store.deleteACPProvider(profileID: profileID) == false)
        #expect(try repository.allProfiles().contains(where: { $0.id == profileID }))
    }

    @Test
    func refreshingProviderProfilesAlsoRefreshesClaudeServiceRegistry() throws {
        let context = try makeModelContext()
        let store = SettingsStore(modelContext: context, persistenceCoordinator: nil)
        let repository = ACPProviderProfileRepository(modelContext: context)
        let claudeService = ClaudeService()
        let profileID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!

        _ = try repository.save(
            profileDraft: ACPProviderProfileDraft(
                id: profileID,
                displayName: "Custom Provider",
                executablePath: "/usr/bin/custom-provider",
                arguments: ["--stdio"],
                isEnabled: true,
                sortOrder: 0,
                validationSnapshot: .init(status: .ready)
            )
        )

        try store.reloadACPProviderProfiles(refreshing: claudeService)

        let registry = try #require(claudeService.executionProviderRegistry)
        let provider = registry.providerIfAvailable(for: .externalACP(profileID: profileID))

        #expect(provider != nil)
        #expect((provider as? DynamicACPExternalExecutionProvider)?.profile.displayName == "Custom Provider")
    }

    private func makeModelContext() throws -> ModelContext {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}

private final class ValidationRuntimeProbe {
    private(set) var configurations: [ACPExternalAgentLaunchConfiguration] = []
    let response: ACPInitializeResponse?

    init(response: ACPInitializeResponse?) {
        self.response = response
    }

    func record(configuration: ACPExternalAgentLaunchConfiguration) {
        configurations.append(configuration)
    }
}

private final class TestValidationRuntime: ACPProviderValidationRuntime {
    private let response: ACPInitializeResponse?

    init(response: ACPInitializeResponse?) {
        self.response = response
    }

    func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
        _ = request
        return try #require(response)
    }

    func close() async {}
}