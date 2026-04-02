//
//  AppSettings.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class AppSettings {
    static let persistenceSchemaVersion = PersistenceSchema.currentVersion

    /// Anthropic API 密钥
    var apiKey: String

    /// 自定义 Base URL（留空则使用官方 https://api.anthropic.com）
    var baseURL: String

    /// 使用的 Claude 模型 ID
    var selectedModel: String

    /// 默认对话执行器 ID
    var defaultExecutionProviderID: String = ConversationExecutionProviderID.builtInAgent.rawValue

    /// 内置执行器默认审批模式
    var builtInDefaultApprovalMode: String = "default"

    /// 主题模式
    var themeMode: ThemeMode

    /// 消息字体大小
    var messageFontSize: Double

    /// 启用 Text Editor Tool（文件读写）
    var enableTextEditorTool: Bool

    /// 启用 Bash Tool（执行 shell 命令）
    var enableBashTool: Bool

    /// Bash / 文件工具的工作目录（留空则使用 HOME）
    var workingDirectory: String

    /// 是否启用 Extended Thinking（适用 Claude 3.7+）
    var enableExtendedThinking: Bool

    /// Extended Thinking token 预算
    var extendedThinkingBudget: Int

    /// JSON array of enabled skill directoryNames, e.g. ["brainstorming","web-search"]
    var enabledSkillNamesJSON: String

    /// 启用 Web Search 工具（Bing 搜索）
    var enableWebSearchTool: Bool

    /// 启用 Web Fetch 工具（获取网页内容）
    var enableWebFetchTool: Bool

    /// 启用通用 LSP 语义工具
    var enableLSPTools: Bool = false

    /// 是否自动启动匹配到的语言服务器
    var autoStartLSPServers: Bool = true

    /// LSP 默认路由策略：automatic / manualBinding / disabled
    var lspDefaultRoutingMode: String = "automatic"

    /// 用户自定义 LSP server profiles 的 JSON 数组
    var lspCustomServerProfilesJSON: String = "[]"

    /// 已安装 provider 的记录数组
    var lspInstalledProvidersJSON: String = "[]"

    /// 已安装并注册到 runtime registry 的 server definitions
    var lspInstalledServerDefinitionsJSON: String = "[]"

    /// 手动绑定 workspace 到 server profile 的 JSON 数组
    var lspManualWorkspaceBindingsJSON: String = "[]"

    /// Ollama API Key（用于 Ollama Web Search）
    var ollamaAPIKey: String = ""   

    /// 启用 Ollama Web Search（优先于 Bing）
    var enableOllamaWebSearch: Bool = false

    /// 启用代理设置（用于内置网络请求与 Bash 环境变量）
    var enableNetworkProxy: Bool = false

    /// 代理 URL，例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:1080
    var networkProxyURL: String = ""

    /// 直连域名列表，逗号 / 空格 / 换行分隔
    var networkProxyBypassList: String = ""

    /// 是否启用简化后的 RMS memory 主链
    var memoryEnabled: Bool = true

    /// RMS memory 注入的上下文预算（千字符级近似预算）
    var memoryContextBudget: Int = 8

    /// 启用后台 Agent 调度
    var backgroundAgentEnabled: Bool = false

    /// 后台 Agent 默认 QoS：background / utility
    var backgroundAgentDefaultQoS: String = "utility"

    /// 后台 Agent 是否默认要求外接电源
    var backgroundAgentRequiresExternalPower: Bool = false

    /// 后台 Agent 是否允许使用联网工具（在全局工具开关之外再做一道限制）
    var backgroundAgentAllowNetworkTools: Bool = false

    /// 后台 Agent 最大并发执行数
    var backgroundAgentMaximumConcurrentRuns: Int = 1

    /// 后台任务观测保留天数
    var backgroundAgentObservationRetentionDays: Int = 30

    /// Sparkle 更新渠道持久化值
    var sparkleUpdateChannelRaw: String = SparkleUpdateChannel.stable.rawValue



    init() {
        self.apiKey = ""
        self.baseURL = ""
        self.selectedModel = "claude-sonnet-4-6"
        self.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue
        self.builtInDefaultApprovalMode = "default"
        self.themeMode = .system
        self.messageFontSize = 14.0
        self.enableTextEditorTool = true
        self.enableBashTool = false
        self.workingDirectory = ""
        self.enableExtendedThinking = false
        self.extendedThinkingBudget = 10000
        self.enabledSkillNamesJSON = "[]"
        self.enableWebSearchTool = false
        self.enableWebFetchTool = false
        self.enableLSPTools = false
        self.autoStartLSPServers = true
        self.lspDefaultRoutingMode = "automatic"
        self.lspCustomServerProfilesJSON = "[]"
        self.lspInstalledProvidersJSON = "[]"
        self.lspInstalledServerDefinitionsJSON = "[]"
        self.ollamaAPIKey = ""
        self.enableOllamaWebSearch = false
        self.enableNetworkProxy = false
        self.networkProxyURL = ""
        self.networkProxyBypassList = ""
        self.memoryEnabled = true
        self.memoryContextBudget = 8
        self.backgroundAgentEnabled = false
        self.backgroundAgentDefaultQoS = "utility"
        self.backgroundAgentRequiresExternalPower = false
        self.backgroundAgentAllowNetworkTools = false
        self.backgroundAgentMaximumConcurrentRuns = 1
        self.backgroundAgentObservationRetentionDays = 30
        self.lspManualWorkspaceBindingsJSON = "[]"
    }
}

// MARK: - Skill Helpers
extension AppSettings {
    var defaultExecutionProviderReference: ExecutionProviderReference {
        get {
            ExecutionProviderReference.decodePersisted(defaultExecutionProviderID)
        }
        set {
            defaultExecutionProviderID = newValue.persistedValue
        }
    }

    var sparkleUpdateChannel: SparkleUpdateChannel {
        get {
            SparkleUpdateChannel(rawValue: sparkleUpdateChannelRaw) ?? .stable
        }
        set {
            sparkleUpdateChannelRaw = newValue.rawValue
        }
    }

    /// Decoded list of enabled skill directoryNames.
    var enabledSkillNames: [String] {
        get {
            (try? JSONDecoder().decode([String].self, from: Data(enabledSkillNamesJSON.utf8))) ?? []
        }
        set {
            enabledSkillNamesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var lspCustomServerProfiles: [LSPServerDefinition] {
        get {
            guard let data = lspCustomServerProfilesJSON.data(using: .utf8),
                  let profiles = try? JSONDecoder().decode([LSPServerDefinition].self, from: data) else {
                return []
            }
            return profiles
        }
        set {
            lspCustomServerProfilesJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var lspInstalledProviders: [LSPInstalledProviderRecord] {
        get {
            guard let data = lspInstalledProvidersJSON.data(using: .utf8),
                  let records = try? JSONDecoder().decode([LSPInstalledProviderRecord].self, from: data) else {
                return []
            }
            return records
        }
        set {
            lspInstalledProvidersJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var lspInstalledServerDefinitions: [LSPServerDefinition] {
        get {
            guard let data = lspInstalledServerDefinitionsJSON.data(using: .utf8),
                  let definitions = try? JSONDecoder().decode([LSPServerDefinition].self, from: data) else {
                return []
            }
            return definitions
        }
        set {
            lspInstalledServerDefinitionsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var lspCustomServerProfilesValidationError: String? {
        let trimmed = lspCustomServerProfilesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            return "自定义 LSP profile JSON 不是有效的 UTF-8 文本。"
        }

        do {
            _ = try JSONDecoder().decode([LSPServerDefinition].self, from: data)
            return nil
        } catch {
            return "自定义 LSP profile JSON 无法解析：\(error.localizedDescription)"
        }
    }

    var isLSPAutoStartEffective: Bool {
        enableLSPTools && autoStartLSPServers
    }
}

// MARK: - Shared Instance
extension AppSettings {
    @discardableResult
    func normalizeGlobalToolPermissionBaseline() -> Bool {
        var didChange = false

        if enableTextEditorTool == false {
            enableTextEditorTool = true
            didChange = true
        }
        if enableBashTool == false {
            enableBashTool = true
            didChange = true
        }
        if enableWebSearchTool == false {
            enableWebSearchTool = true
            didChange = true
        }
        if enableWebFetchTool == false {
            enableWebFetchTool = true
            didChange = true
        }
        if enableLSPTools == false {
            enableLSPTools = true
            didChange = true
        }

        return didChange
    }

    /// 获取或创建单例设置
    @MainActor
    static func getOrCreate(
        in context: ModelContext,
        persistenceCoordinator: PersistenceCoordinator? = nil
    ) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            let didNormalize = existing.normalizeGlobalToolPermissionBaseline()
            if didNormalize {
                if let persistenceCoordinator {
                    try? persistenceCoordinator.save(
                        context,
                        domain: .settings,
                        userMessage: "工具权限全局基线未成功更新"
                    )
                } else {
                    try? context.save()
                }
            }
            return existing
        }

        let settings = AppSettings()
        _ = settings.normalizeGlobalToolPermissionBaseline()
        context.insert(settings)
        if let persistenceCoordinator {
            try? persistenceCoordinator.save(
                context,
                domain: .settings,
                userMessage: "设置初始化未成功保存"
            )
        } else {
            try? context.save()
        }
        return settings
    }

    static func testFixture(
        apiKey: String = "",
        selectedModel: String = "claude-sonnet-4-6",
        installedDefinitions: [LSPServerDefinition] = []
    ) -> AppSettings {
        let settings = AppSettings()
        settings.apiKey = apiKey
        settings.selectedModel = selectedModel
        settings.lspInstalledServerDefinitions = installedDefinitions
        return settings
    }
}

// MARK: - Available Models
extension AppSettings {
    static func availableModelOptions(inheritingTitle: String? = nil) -> [ExecutionOptionItem] {
        var options: [ExecutionOptionItem] = []
        if let inheritingTitle {
            options.append(ExecutionOptionItem(id: "", title: inheritingTitle))
        }
        options.append(contentsOf: availableModels.map { ExecutionOptionItem(id: $0.id, title: $0.name) })
        return options
    }

    static func displayName(for modelID: String) -> String {
        availableModels.first(where: { $0.id == modelID })?.name ?? modelID
    }

    static let availableModels: [(id: String, name: String)] = [
        // Claude 4
        ("claude-opus-4-6", "Claude Opus 4.6"),
        ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
        ("claude-opus-4-5", "Claude Opus 4.5"),
        ("claude-sonnet-4-5", "Claude Sonnet 4.5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5"),
        // Claude 3
        ("claude-3-7-sonnet-20250219", "Claude 3.7 Sonnet"),
        ("claude-3-5-sonnet-latest", "Claude 3.5 Sonnet"),
        ("claude-3-5-haiku-latest", "Claude 3.5 Haiku"),
    ]
}
