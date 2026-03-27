import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct DynamicACPExternalExecutionProviderTests {
    @Test
    func buildRuntimeClientUsesProfileScopedTerminalRuntime() async throws {
        let capture = RuntimeClientCapture()
        let terminalStore = ExternalACPTerminalRuntimeStore()
        let firstProfile = ACPProviderProfile(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            displayName: "First",
            executablePath: "/usr/bin/first",
            arguments: ["--stdio"]
        )
        let secondProfile = ACPProviderProfile(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            displayName: "Second",
            executablePath: "/usr/bin/second",
            arguments: ["--stdio"]
        )

        let firstProvider = DynamicACPExternalExecutionProvider(
            profile: firstProfile,
            terminalRuntimeFactory: { sessionID, workingDirectory in
                await terminalStore.runtime(
                    for: sessionID,
                    providerReference: .externalACP(profileID: firstProfile.id),
                    workingDirectory: workingDirectory
                )
            },
            sessionRuntimeResetter: { sessionID in
                await terminalStore.reset(
                    for: sessionID,
                    providerReference: .externalACP(profileID: firstProfile.id)
                )
            },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, terminalRuntime, _, _, _ in
                await capture.record(runtime: terminalRuntime)
                return FakeDynamicRuntimeClient()
            }
        )
        let secondProvider = DynamicACPExternalExecutionProvider(
            profile: secondProfile,
            terminalRuntimeFactory: { sessionID, workingDirectory in
                await terminalStore.runtime(
                    for: sessionID,
                    providerReference: .externalACP(profileID: secondProfile.id),
                    workingDirectory: workingDirectory
                )
            },
            sessionRuntimeResetter: { sessionID in
                await terminalStore.reset(
                    for: sessionID,
                    providerReference: .externalACP(profileID: secondProfile.id)
                )
            },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, terminalRuntime, _, _, _ in
                await capture.record(runtime: terminalRuntime)
                return FakeDynamicRuntimeClient()
            }
        )

        _ = try await firstProvider.buildRuntimeClient(
            configuration: firstProfile,
            localSessionID: "session-a",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            permissionResolver: { _, _ in nil as ACPRequestPermissionResponse? },
            updateSink: { _ in }
        )
        _ = try await secondProvider.buildRuntimeClient(
            configuration: secondProfile,
            localSessionID: "session-a",
            workingDirectory: FileManager.default.temporaryDirectory.path,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .actLimited),
            permissionResolver: { _, _ in nil as ACPRequestPermissionResponse? },
            updateSink: { _ in }
        )

        let runtimeIdentifiers = await capture.runtimeIdentifiers
        #expect(runtimeIdentifiers.count == 2)
        #expect(runtimeIdentifiers[0] != runtimeIdentifiers[1])
    }

    @Test
    func bindingStoreIsolatesRemoteBindingsByProviderReference() throws {
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()
        let store = ACPExternalSessionBindingStore(modelContext: harness.context)
        let firstReference = ExecutionProviderReference.externalACP(
            profileID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let secondReference = ExecutionProviderReference.externalACP(
            profileID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )

        _ = try store.upsert(
            sessionID: harness.session.sessionId,
            providerReference: firstReference,
            remoteSessionID: "remote-a",
            agentVersion: "1.0.0",
            capabilities: nil,
            selectedModel: nil,
            selectedAgentName: nil
        )
        _ = try store.upsert(
            sessionID: harness.session.sessionId,
            providerReference: secondReference,
            remoteSessionID: "remote-b",
            agentVersion: "1.0.0",
            capabilities: nil,
            selectedModel: nil,
            selectedAgentName: nil
        )

        #expect(try store.binding(for: harness.session.sessionId, providerReference: firstReference)?.remoteSessionID == "remote-a")
        #expect(try store.binding(for: harness.session.sessionId, providerReference: secondReference)?.remoteSessionID == "remote-b")
    }

    @Test
    func prepareForActivationLoadsRemoteConfigurationForDynamicProvider() async throws {
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()
        let profile = ACPProviderProfile(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            displayName: "Dynamic ACP",
            executablePath: "/usr/bin/dynamic-acp",
            arguments: ["--stdio"]
        )
        let provider = DynamicACPExternalExecutionProvider(
            profile: profile,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, _ in
                DynamicACPTestRuntimeClient(handshake: .fixture(remoteSessionID: "remote-config"))
            }
        )

        await provider.prepareForActivation(
            session: harness.session,
            isActiveProvider: true,
            modelContext: harness.context,
            trigger: .selection
        )

        let configuration = try #require(provider.remoteSessionConfiguration(localSessionID: harness.session.sessionId))
        #expect(configuration.modes?.currentModeID == "plan")
        #expect(configuration.modelConfigOption?.currentValue == "gpt-5.4")
        #expect((provider as (any ACPRemoteSessionConfigurationControlling)) != nil)
    }

    @Test
    func sendUsesACPFlowAndPublishesRemoteCommands() async throws {
        let harness = try InMemoryAppHarness.makeConfiguredSettingsScenario()
        let profile = ACPProviderProfile(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            displayName: "Dynamic ACP",
            executablePath: "/usr/bin/dynamic-acp",
            arguments: ["--stdio"]
        )
        var preferences = harness.session.executionPreferences
        preferences.applyACPModeSelection(providerReference: .externalACP(profileID: profile.id), modeID: "plan")
        preferences.applyACPConfigSelection(
            providerReference: .externalACP(profileID: profile.id),
            configID: "model",
            value: "gpt-5.4",
            modelConfigID: "model",
            approvalsConfigID: nil
        )
        harness.session.executionPreferences = preferences

        let clientBox = DynamicACPTestRuntimeClientBox()
        let provider = DynamicACPExternalExecutionProvider(
            profile: profile,
            terminalRuntimeFactory: { _, _ in TerminalTaskRuntime.makeForTests() },
            permissionCenter: ACPPermissionCenter(),
            runtimeClientFactory: { _, _, _, _, updateSink in
                let client = DynamicACPTestRuntimeClient(
                    handshake: .fixture(remoteSessionID: "remote-send"),
                    updateSink: updateSink
                )
                await clientBox.set(client)
                return client
            }
        )

        try await provider.send(
            ConversationExecutionRequest(
                text: "请检查这个项目",
                session: harness.session,
                modelID: "ignored-for-dynamic-acp",
                selectedFilePath: nil,
                selectedText: nil,
                directives: [],
                modelContext: harness.context
            )
        )

        let client = try #require(await clientBox.client)
        #expect(await client.promptTexts == ["请检查这个项目"])
        #expect(await client.setModeRequests.isEmpty)
        #expect(await client.setConfigRequests == [ConfigRequest(configID: "model", value: "gpt-5.4")])

        let commands = (provider as any ACPChatSlashCommandSource).remoteCommands(localSessionID: harness.session.sessionId)
        #expect(commands.map(\.name) == ["/review"])
        #expect(commands.first?.providerReference == .externalACP(profileID: profile.id))
        #expect(commands.first?.providerDisplayName == "Dynamic ACP")
    }
}

private actor RuntimeClientCapture {
    private(set) var runtimeIdentifiers: [ObjectIdentifier] = []

    func record(runtime: TerminalTaskRuntime) {
        runtimeIdentifiers.append(ObjectIdentifier(runtime))
    }
}

private final class FakeDynamicRuntimeClient: ACPExternalProviderRuntimeTransportClient {
    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        ACPExternalAgentCapabilitySnapshot(loadSession: true, supportsSessionModelOverride: false, agentVersion: nil)
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        _ = workingDirectory
        _ = remoteSessionID
        return nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        _ = workingDirectory
        return ACPExternalAgentSessionHandshake(remoteSessionID: "remote", capabilities: ACPExternalAgentCapabilitySnapshot(loadSession: true, supportsSessionModelOverride: false, agentVersion: nil))
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {
        _ = modeID
        _ = sessionID
    }

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        _ = configID
        _ = value
        _ = sessionID
        return []
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        _ = text
        _ = sessionID
        return .endTurn
    }

    func cancel(sessionID: String) async throws {
        _ = sessionID
    }

    func close() async {}
}

private actor DynamicACPTestRuntimeClientBox {
    private(set) var client: DynamicACPTestRuntimeClient?

    func set(_ client: DynamicACPTestRuntimeClient) {
        self.client = client
    }
}

private struct ConfigRequest: Equatable, Sendable {
    let configID: String
    let value: String
}

private final class DynamicACPTestRuntimeClient: ACPExternalProviderRuntimeTransportClient, @unchecked Sendable {
    private let handshake: ACPExternalAgentSessionHandshake
    private let updateSink: (@Sendable (CopilotACPUpdate) async -> Void)?

    private let state = DynamicACPTestRuntimeState()

    init(
        handshake: ACPExternalAgentSessionHandshake,
        updateSink: (@Sendable (CopilotACPUpdate) async -> Void)? = nil
    ) {
        self.handshake = handshake
        self.updateSink = updateSink
    }

    var promptTexts: [String] {
        get async { await state.promptTexts }
    }

    var setModeRequests: [String] {
        get async { await state.setModeRequests }
    }

    var setConfigRequests: [ConfigRequest] {
        get async { await state.setConfigRequests }
    }

    func initializeIfNeeded() async throws -> ACPExternalAgentCapabilitySnapshot {
        handshake.capabilities
    }

    func loadSessionIfPossible(workingDirectory: String, remoteSessionID: String) async throws -> ACPExternalAgentSessionHandshake? {
        _ = workingDirectory
        _ = remoteSessionID
        return nil
    }

    func createSession(workingDirectory: String) async throws -> ACPExternalAgentSessionHandshake {
        _ = workingDirectory
        return handshake
    }

    func setSessionMode(_ modeID: String, sessionID: String) async throws {
        _ = sessionID
        await state.recordMode(modeID)
    }

    func setSessionConfigOption(_ configID: String, value: String, sessionID: String) async throws -> [ACPSessionConfigOption] {
        _ = sessionID
        await state.recordConfig(ConfigRequest(configID: configID, value: value))
        return [
            ACPSessionConfigOption(
                id: configID,
                category: .model,
                currentValue: value,
                options: .ungrouped([
                    ACPSessionConfigSelectOption(description: nil, name: value, value: value)
                ]),
                type: "string"
            )
        ]
    }

    func prompt(text: String, sessionID: String) async throws -> ACPStopReason {
        await state.recordPrompt(text)
        if let updateSink {
            await updateSink(
                .session(
                    .availableCommandsUpdate(
                        ACPAvailableCommandsUpdatePayload(
                            availableCommands: [
                                ACPAvailableCommand(
                                    description: "Review the workspace",
                                    input: ACPAvailableCommandInput(hint: "target"),
                                    name: "/review"
                                )
                            ]
                        )
                    )
                )
            )
            await updateSink(
                .session(
                    .agentMessageChunk(
                        ACPContentChunk(
                            content: .text(ACPTextContentBlock(meta: nil, annotations: nil, text: "分析完成"))
                        )
                    )
                )
            )
        }
        _ = sessionID
        return .endTurn
    }

    func cancel(sessionID: String) async throws {
        _ = sessionID
    }

    func close() async {}
}

private actor DynamicACPTestRuntimeState {
    private(set) var promptTexts: [String] = []
    private(set) var setModeRequests: [String] = []
    private(set) var setConfigRequests: [ConfigRequest] = []

    func recordPrompt(_ text: String) {
        promptTexts.append(text)
    }

    func recordMode(_ modeID: String) {
        setModeRequests.append(modeID)
    }

    func recordConfig(_ request: ConfigRequest) {
        setConfigRequests.append(request)
    }
}

private extension ACPExternalAgentSessionHandshake {
    static func fixture(remoteSessionID: String) -> ACPExternalAgentSessionHandshake {
        ACPExternalAgentSessionHandshake(
            remoteSessionID: remoteSessionID,
            capabilities: ACPExternalAgentCapabilitySnapshot(
                loadSession: true,
                supportsSessionModelOverride: true,
                agentVersion: "1.0.0"
            ),
            configurationSnapshot: ACPExternalAgentSessionConfigurationSnapshot(
                configOptions: [
                    ACPSessionConfigOption(
                        id: "model",
                        category: .model,
                        currentValue: "gpt-5.4",
                        options: .ungrouped([
                            ACPSessionConfigSelectOption(description: nil, name: "GPT-5.4", value: "gpt-5.4")
                        ]),
                        type: "string"
                    )
                ],
                modes: ACPSessionModeState(
                    meta: nil,
                    availableModes: [
                        ACPSessionMode(meta: nil, description: "Plan mode", id: "plan", name: "Plan")
                    ],
                    currentModeID: "plan"
                )
            )
        )
    }
}