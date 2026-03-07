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
}

// MARK: - Shared Instance
extension AppSettings {
    /// 获取或创建单例设置
    static func getOrCreate(in context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        let settings = AppSettings()
        context.insert(settings)
        try? context.save()
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
