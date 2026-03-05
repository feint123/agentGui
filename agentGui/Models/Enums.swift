//
//  Enums.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

// MARK: - Message Direction
/// 消息方向枚举
enum MessageDirection: String, Codable {
    case user = "user"           // 用户发送
    case agent = "agent"         // Claude 响应（存储为 assistant）
    case system = "system"       // 系统消息
}

// MARK: - Content Type
/// 内容类型枚举
enum ContentType: String, Codable {
    case text = "text"           // 纯文本
    case toolCall = "tool_call"  // 工具调用
    case thought = "thought"     // 思考过程
    case error = "error"         // 错误信息
}

// MARK: - Message Status
/// 消息状态枚举
enum MessageStatus: String, Codable {
    case pending = "pending"     // 发送中
    case completed = "completed" // 已完成
    case failed = "failed"       // 失败
    case cancelled = "cancelled" // 已取消
}

// MARK: - Tool Kind
/// 工具类型枚举
enum ToolKind: String, Codable {
    case read = "read"
    case edit = "edit"
    case execute = "execute"
    case search = "search"
    case delete = "delete"
    case think = "think"
    case fetch = "fetch"
    case plan = "plan"
    case switchMode = "switch_mode"
    case other = "other"

    var icon: String {
        switch self {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .execute: return "terminal"
        case .search: return "magnifyingglass"
        case .delete: return "trash"
        case .think: return "brain"
        case .fetch: return "arrow.down.doc"
        case .plan: return "list.bullet"
        case .switchMode: return "arrow.triangle.2.circlepath"
        case .other: return "gearshape"
        }
    }

    var displayName: String {
        switch self {
        case .read: return "读取文件"
        case .edit: return "写入文件"
        case .execute: return "执行命令"
        case .search: return "搜索"
        case .delete: return "删除"
        case .think: return "思考"
        case .fetch: return "获取"
        case .plan: return "计划"
        case .switchMode: return "切换模式"
        case .other: return "其他"
        }
    }
}

// MARK: - Tool Status
/// 工具状态枚举
enum ToolStatus: String, Codable {
    case inProgress = "in_progress"
    case success = "success"
    case failed = "failed"
    case cancelled = "cancelled"

    var displayName: String {
        switch self {
        case .inProgress: return "进行中"
        case .success: return "成功"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var icon: String {
        switch self {
        case .inProgress: return "circle.dashed"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
}

// MARK: - Theme Mode
/// 主题模式枚举
enum ThemeMode: String, Codable, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }
}
