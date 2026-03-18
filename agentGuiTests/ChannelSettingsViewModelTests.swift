import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ChannelSettingsViewModelTests {
    @Test func saveFeishuSettingsPersistsBindingAndCredentials() throws {
        let harness = try ChannelSettingsHarness.make()

        harness.viewModel.feishuEnabled = true
        harness.viewModel.feishuDisplayName = "我的飞书 Bot"
        harness.viewModel.feishuAppID = "cli_test"
        harness.viewModel.feishuAppSecret = "secret_test"
        harness.viewModel.feishuMessageFormat = .interactive
        harness.viewModel.authorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)

        try harness.viewModel.saveFeishuSettings()

        let bindings = try harness.context.fetch(FetchDescriptor<ChannelAccountBinding>())
        let credentials = try #require(try harness.credentialStore.load())

        #expect(bindings.count == 1)
        #expect(bindings.first?.isEnabled == true)
        #expect(bindings.first?.displayName == "我的飞书 Bot")
        #expect(bindings.first?.authorizationPolicy.preset == .actLimited)
        #expect(bindings.first.map { FeishuChannelSettings(binding: $0).messageFormat } == .interactive)
        #expect(credentials.appID == "cli_test")
        #expect(credentials.appSecret == "secret_test")
    }

    @Test func saveAuthorizationPolicyPersistsWithoutSubmittingFeishuCredentials() throws {
        let harness = try ChannelSettingsHarness.make()

        harness.viewModel.authorizationPolicy = ToolAuthorizationPolicy(preset: .maintain)

        try harness.viewModel.saveAuthorizationPolicy()

        let bindings = try harness.context.fetch(FetchDescriptor<ChannelAccountBinding>())
        #expect(bindings.count == 1)
        #expect(bindings.first?.authorizationPolicy.preset == .maintain)
        #expect(bindings.first?.displayName == "")
        #expect(bindings.first?.isEnabled == false)
        #expect(harness.viewModel.authorizationStatusText == "已保存")
        #expect((try? harness.credentialStore.load()) == nil)
    }

    @Test func saveAuthorizationPolicyUpdatesAllChannelBindings() throws {
        let harness = try ChannelSettingsHarness.make()
        let primaryBinding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            displayName: "主渠道",
            isEnabled: true,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly)
        )
        let secondaryBinding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.backup",
            displayName: "备用渠道",
            isEnabled: false,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .observeOnly)
        )
        harness.context.insert(primaryBinding)
        harness.context.insert(secondaryBinding)
        try harness.context.save()

        harness.viewModel.authorizationPolicy = ToolAuthorizationPolicy(preset: .actLimited)

        try harness.viewModel.saveAuthorizationPolicy()

        let bindings = try harness.context.fetch(FetchDescriptor<ChannelAccountBinding>())
        #expect(bindings.count == 2)
        #expect(bindings.allSatisfy { $0.authorizationPolicy.preset == .actLimited })
    }

    @Test func loadingExistingBindingReflectsCurrentState() throws {
        let harness = try ChannelSettingsHarness.make()
        let binding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            displayName: "团队机器人",
            isEnabled: true,
            authorizationPolicy: ToolAuthorizationPolicy(preset: .maintain)
        )
        harness.context.insert(binding)
        try harness.context.save()
        try harness.credentialStore.save(appID: "cli_existing", appSecret: "secret_existing")

        harness.viewModel.load()

        #expect(harness.viewModel.feishuEnabled == true)
        #expect(harness.viewModel.feishuDisplayName == "团队机器人")
        #expect(harness.viewModel.feishuAppID == "cli_existing")
        #expect(harness.viewModel.feishuMessageFormat == .text)
        #expect(harness.viewModel.authorizationPolicy.preset == .maintain)
        #expect(harness.viewModel.connectionStatusText == "已配置")
    }

    @Test func loadingExistingBindingReflectsSavedMessageFormat() throws {
        let harness = try ChannelSettingsHarness.make()
        let binding = ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            displayName: "团队机器人",
            isEnabled: true
        )
        FeishuChannelSettings(messageFormat: .post).apply(to: binding)
        harness.context.insert(binding)
        try harness.context.save()

        harness.viewModel.load()

        #expect(harness.viewModel.feishuMessageFormat == .post)
    }

    @Test func runtimeConnectionStatusReflectsObservableStore() throws {
        let store = FeishuChannelConnectionStatusStore()
        let harness = try ChannelSettingsHarness.make(connectionStatusStore: store)

        store.reportConnecting()
        #expect(harness.viewModel.runtimeConnectionStatusText == "连接中")
        #expect(harness.viewModel.lastRuntimeErrorText == nil)

        store.reportFailure("握手失败")
        #expect(harness.viewModel.runtimeConnectionStatusText == "连接失败")
        #expect(harness.viewModel.lastRuntimeErrorText == "握手失败")
    }

    @Test func handshakeDiagnosticsReflectParsedResponseHeaders() throws {
        let store = FeishuChannelConnectionStatusStore()
        let harness = try ChannelSettingsHarness.make(connectionStatusStore: store)

        store.reportHandshakeResponse(
            httpStatusCode: 101,
            headers: [
                "handshake-status": "514",
                "handshake-msg": "auth failed",
                "handshake-autherrcode": "1000040350"
            ]
        )

        #expect(harness.viewModel.handshakeDiagnosticsText == "HTTP 101 · handshake-status 514 · auth 1000040350 · auth failed")
    }

    @Test func connectingAndConnectedStatesClearStaleHandshakeDiagnostics() throws {
        let store = FeishuChannelConnectionStatusStore()

        store.reportHandshakeResponse(
            httpStatusCode: 101,
            headers: [
                "handshake-status": "514",
                "handshake-msg": "auth failed",
                "handshake-autherrcode": "1000040350"
            ]
        )
        store.reportSocketClosed(code: 1006, reason: "abnormal")
        store.reportFailure("握手失败")

        store.reportConnecting()
        #expect(store.lastErrorMessage == nil)
        #expect(store.lastHandshakeHTTPStatus == nil)
        #expect(store.lastHandshakeStatus == nil)
        #expect(store.lastHandshakeMessage == nil)
        #expect(store.lastHandshakeAuthErrorCode == nil)
        #expect(store.lastCloseCode == nil)
        #expect(store.lastCloseReason == nil)

        store.reportHandshakeResponse(
            httpStatusCode: 101,
            headers: [
                "handshake-status": "403",
                "handshake-msg": "forbidden"
            ]
        )
        store.reportSocketClosed(code: 1001, reason: "going away")
        store.reportConnected(url: URL(string: "wss://ws.example.com/path?service_id=42")!, serviceID: 42, at: .now)

        #expect(store.phase == .connected)
        #expect(store.lastHandshakeHTTPStatus == nil)
        #expect(store.lastHandshakeStatus == nil)
        #expect(store.lastHandshakeMessage == nil)
        #expect(store.lastHandshakeAuthErrorCode == nil)
        #expect(store.lastCloseCode == nil)
        #expect(store.lastCloseReason == nil)
    }
}

@MainActor
private struct ChannelSettingsHarness {
    let container: ModelContainer
    let context: ModelContext
    let credentialStore: FeishuCredentialStore
    let viewModel: ChannelSettingsViewModel

    static func make(connectionStatusStore: FeishuChannelConnectionStatusStore? = nil) throws -> ChannelSettingsHarness {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ChannelAccountBinding.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let credentialStore = FeishuCredentialStore(backend: InMemoryFeishuCredentialBackend())
        let resolvedConnectionStatusStore = connectionStatusStore ?? FeishuChannelConnectionStatusStore()
        let viewModel = ChannelSettingsViewModel(
            modelContext: context,
            persistenceCoordinator: nil,
            credentialStore: credentialStore,
            connectionStatusStore: resolvedConnectionStatusStore
        )
        return ChannelSettingsHarness(
            container: container,
            context: context,
            credentialStore: credentialStore,
            viewModel: viewModel
        )
    }
}