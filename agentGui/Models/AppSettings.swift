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

    /// 启用反思与自我修正循环（每次 end_turn 后触发，额外消耗一次 API 调用）
    var enableReflection: Bool = false

    /// 反思置信度阈值（低于此值时触发重试，0.5–1.0）
    var reflectionConfidenceThreshold: Double = 0.7

    /// 启用项目级创作记忆运行时
    var enableStoryMemory: Bool = false

    /// 是否在写作流程中自动抽取剧情事件和角色状态
    var storyMemoryAutoExtract: Bool = true

    /// 每次 prompt 组装最多包含多少个 story memory slice
    var storyMemoryPromptBudget: Int = 6

    /// 当前创作记忆项目绑定模式：manual / session / auto
    var storyMemoryProjectMode: String = "auto"

    /// 启用统一记忆运行时读取路径
    var enableUnifiedMemoryRuntime: Bool = false

    /// 统一记忆运行时的上下文预算（千字符级近似预算）
    var unifiedMemoryContextBudget: Int = 8

    /// 是否启用统一记忆治理层
    var enableMemoryGovernance: Bool = true

    /// 是否启用统一写路径
    var enableUnifiedMemoryWritePath: Bool = true

    /// 是否允许后台记忆巩固
    var enableBackgroundMemoryConsolidation: Bool = true

    /// 需要用户确认的默认置信度阈值
    var memoryConfirmationThreshold: Double = 0.6

    /// 是否启用 TTL sweep
    var enableMemoryTTLSweep: Bool = true

    /// 后台记忆调度轮询周期（秒）
    var memoryBackgroundSchedulerIntervalSeconds: Int = 30

    /// TTL sweep 调度周期（秒）
    var memoryTTLSweepIntervalSeconds: Int = 300


    init() {
        self.apiKey = ""
        self.baseURL = ""
        self.selectedModel = "claude-sonnet-4-6"
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
        self.ollamaAPIKey = ""
        self.enableOllamaWebSearch = false
        self.enableNetworkProxy = false
        self.networkProxyURL = ""
        self.networkProxyBypassList = ""
        self.enableReflection = false
        self.reflectionConfidenceThreshold = 0.7
        self.enableStoryMemory = false
        self.storyMemoryAutoExtract = true
        self.storyMemoryPromptBudget = 6
        self.storyMemoryProjectMode = "auto"
        self.enableUnifiedMemoryRuntime = false
        self.unifiedMemoryContextBudget = 8
        self.enableMemoryGovernance = true
        self.enableUnifiedMemoryWritePath = true
        self.enableBackgroundMemoryConsolidation = true
        self.memoryConfirmationThreshold = 0.6
        self.enableMemoryTTLSweep = true
        self.memoryBackgroundSchedulerIntervalSeconds = 30
        self.memoryTTLSweepIntervalSeconds = 300
        self.lspManualWorkspaceBindingsJSON = "[]"
    }
}

// MARK: - Skill Helpers
extension AppSettings {
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
    /// 获取或创建单例设置
    @MainActor
    static func getOrCreate(
        in context: ModelContext,
        persistenceCoordinator: PersistenceCoordinator? = nil
    ) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let settings = AppSettings()
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

    @MainActor
    static func testFixture(
        apiKey: String = "",
        selectedModel: String = "claude-sonnet-4-6"
    ) -> AppSettings {
        let settings = AppSettings()
        settings.apiKey = apiKey
        settings.selectedModel = selectedModel
        return settings
    }
}

// MARK: - Available Models
extension AppSettings {
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
