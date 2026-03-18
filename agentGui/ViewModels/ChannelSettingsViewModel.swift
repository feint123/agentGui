import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ChannelSettingsViewModel {
    private let modelContext: ModelContext
    private let persistenceCoordinator: PersistenceCoordinator?
    private let credentialStore: FeishuCredentialStore
    private let connectionStatusStore: FeishuChannelConnectionStatusStore

    var feishuEnabled: Bool = false
    var feishuDisplayName: String = ""
    var feishuAppID: String = ""
    var feishuAppSecret: String = ""
    private(set) var connectionStatusText: String = "未配置"
    var runtimeConnectionStatusText: String {
        connectionStatusStore.phase.displayText
    }

    var lastRuntimeErrorText: String? {
        connectionStatusStore.lastErrorMessage
    }

    var handshakeDiagnosticsText: String? {
        guard let httpStatus = connectionStatusStore.lastHandshakeHTTPStatus else {
            return nil
        }

        var parts = ["HTTP \(httpStatus)"]
        if let handshakeStatus = connectionStatusStore.lastHandshakeStatus {
            parts.append("handshake-status \(handshakeStatus)")
        }
        if let authErrorCode = connectionStatusStore.lastHandshakeAuthErrorCode {
            parts.append("auth \(authErrorCode)")
        }
        if let message = connectionStatusStore.lastHandshakeMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    init(
        modelContext: ModelContext,
        persistenceCoordinator: PersistenceCoordinator?,
        credentialStore: FeishuCredentialStore? = nil,
        connectionStatusStore: FeishuChannelConnectionStatusStore? = nil
    ) {
        self.modelContext = modelContext
        self.persistenceCoordinator = persistenceCoordinator
        self.credentialStore = credentialStore ?? FeishuCredentialStore()
        self.connectionStatusStore = connectionStatusStore ?? .shared
        load()
    }

    func load() {
        let binding = fetchBinding()
        feishuEnabled = binding?.isEnabled ?? false
        feishuDisplayName = binding?.displayName ?? ""

        if let credentials = try? credentialStore.load() {
            feishuAppID = credentials.appID
            feishuAppSecret = credentials.appSecret
        } else {
            feishuAppID = ""
            feishuAppSecret = ""
        }

        updateConnectionStatus()
    }

    func save() throws {
        let binding = fetchBinding() ?? ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default"
        )
        let isNewBinding = fetchBinding() == nil

        binding.displayName = feishuDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.isEnabled = feishuEnabled
        binding.updatedAt = Date()

        if isNewBinding {
            modelContext.insert(binding)
        }

        let trimmedAppID = feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppSecret = feishuAppSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAppID.isEmpty || !trimmedAppSecret.isEmpty {
            try credentialStore.save(appID: trimmedAppID, appSecret: trimmedAppSecret)
        }

        if let persistenceCoordinator {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: "渠道设置未成功保存"
            )
        } else {
            try modelContext.save()
        }

        updateConnectionStatus()
    }

    private func fetchBinding() -> ChannelAccountBinding? {
        (try? modelContext.fetch(FetchDescriptor<ChannelAccountBinding>()))?
            .first(where: { $0.channelKind == .feishu })
    }

    private func updateConnectionStatus() {
        connectionStatusText = (feishuAppID.isEmpty || feishuAppSecret.isEmpty) ? "未配置" : "已配置"
    }
}