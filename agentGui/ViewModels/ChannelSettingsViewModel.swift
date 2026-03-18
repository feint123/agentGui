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
    var feishuMessageFormat: FeishuMessageFormat = .text
    var authorizationPolicy: ToolAuthorizationPolicy = ToolAuthorizationPolicy()
    private(set) var connectionStatusText: String = "未配置"
    private(set) var authorizationStatusText: String = "未保存"
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
        let bindings = fetchBindings()
        feishuEnabled = binding?.isEnabled ?? false
        feishuDisplayName = binding?.displayName ?? ""
        feishuMessageFormat = binding.map { FeishuChannelSettings(binding: $0).messageFormat } ?? .text
        authorizationPolicy = bindings.first?.authorizationPolicy ?? ToolAuthorizationPolicy()

        if let credentials = try? credentialStore.load() {
            feishuAppID = credentials.appID
            feishuAppSecret = credentials.appSecret
        } else {
            feishuAppID = ""
            feishuAppSecret = ""
        }

        updateConnectionStatus()
        authorizationStatusText = bindings.isEmpty ? "未保存" : "已保存"
    }

    func saveFeishuSettings() throws {
        let binding = fetchBinding() ?? ChannelAccountBinding(
            channelKind: .feishu,
            configurationKey: "feishu.default",
            authorizationPolicy: authorizationPolicy
        )
        let isNewBinding = fetchBinding() == nil

        binding.displayName = feishuDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        binding.isEnabled = feishuEnabled
        FeishuChannelSettings(messageFormat: feishuMessageFormat).apply(to: binding)
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

    func saveAuthorizationPolicy() throws {
        let bindings = fetchBindings()
        let now = Date()

        if bindings.isEmpty {
            let binding = ChannelAccountBinding(
                channelKind: .feishu,
                configurationKey: "feishu.default",
                authorizationPolicy: authorizationPolicy,
                updatedAt: now
            )
            modelContext.insert(binding)
        } else {
            for binding in bindings {
                binding.authorizationPolicy = authorizationPolicy
                binding.updatedAt = now
            }
        }

        try persistChanges(userMessage: "渠道权限未成功保存")
        authorizationStatusText = "已保存"
    }

    private func fetchBinding() -> ChannelAccountBinding? {
        fetchBindings()
            .first(where: { $0.channelKind == .feishu })
    }

    private func fetchBindings() -> [ChannelAccountBinding] {
        ((try? modelContext.fetch(FetchDescriptor<ChannelAccountBinding>())) ?? [])
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func persistChanges(userMessage: String) throws {
        if let persistenceCoordinator {
            try persistenceCoordinator.save(
                modelContext,
                domain: .settings,
                userMessage: userMessage
            )
        } else {
            try modelContext.save()
        }
    }

    private func updateConnectionStatus() {
        connectionStatusText = (feishuAppID.isEmpty || feishuAppSecret.isEmpty) ? "未配置" : "已配置"
    }
}