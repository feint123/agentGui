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
    /// 主题模式
    var themeMode: ThemeMode

    /// 自动批准策略
    var autoApprovePolicy: AutoApprovePolicy

    /// 启动时自动连接上次 Agent
    var autoConnectOnStartup: Bool

    /// 默认 Agent ID
    var defaultAgentId: UUID?

    /// 最大会话历史数量
    var maxSessionHistory: Int

    /// 消息字体大小
    var messageFontSize: Double

    /// 是否显示工具调用详情
    var showToolCallDetails: Bool

    init() {
        self.themeMode = .system
        self.autoApprovePolicy = .askAlways
        self.autoConnectOnStartup = false
        self.defaultAgentId = nil
        self.maxSessionHistory = 1000
        self.messageFontSize = 13.0
        self.showToolCallDetails = true
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

// MARK: - Computed Properties
extension AppSettings {
    /// 是否自动批准文件读取
    var autoApproveFileReads: Bool {
        return autoApprovePolicy == .approveReads || autoApprovePolicy == .approveAll
    }

    /// 是否自动批准所有操作
    var autoApproveAll: Bool {
        return autoApprovePolicy == .approveAll
    }
}
