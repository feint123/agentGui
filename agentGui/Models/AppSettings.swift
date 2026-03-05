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

    init() {
        self.apiKey = ""
        self.baseURL = ""
        self.selectedModel = "claude-opus-4-5"
        self.themeMode = .system
        self.messageFontSize = 14.0
        self.enableTextEditorTool = true
        self.enableBashTool = false
        self.workingDirectory = ""
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
        ("claude-opus-4-5", "Claude Opus 4.5"),
        ("claude-sonnet-4-5", "Claude Sonnet 4.5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5"),
        ("claude-3-7-sonnet-20250219", "Claude 3.7 Sonnet"),
        ("claude-3-5-sonnet-latest", "Claude 3.5 Sonnet"),
        ("claude-3-5-haiku-latest", "Claude 3.5 Haiku"),
    ]
}
