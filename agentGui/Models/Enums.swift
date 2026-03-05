//
//  Enums.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

// MARK: - Agent Type
/// Agent 类型枚举
enum AgentType: String, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case openCode = "opencode"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .openCode: return "OpenCode"
        case .custom: return "自定义"
        }
    }
}

// MARK: - Connection Type
/// 连接类型枚举
enum ConnectionType: String, Codable, CaseIterable {
    case stdio = "stdio"       // 本地进程
    case websocket = "websocket" // 远程服务

    var displayName: String {
        switch self {
        case .stdio: return "本地进程 (stdio)"
        case .websocket: return "远程服务 (WebSocket)"
        }
    }
}

// MARK: - Session Mode
/// 会话模式枚举
enum SessionMode: String, Codable, CaseIterable {
    case code = "code"       // 代码模式
    case chat = "chat"       // 聊天模式
    case plan = "plan"       // 计划模式
    case ask = "ask"         // 询问模式

    var displayName: String {
        switch self {
        case .code: return "代码"
        case .chat: return "聊天"
        case .plan: return "计划"
        case .ask: return "询问"
        }
    }

    var icon: String {
        switch self {
        case .code: return "curlybraces"
        case .chat: return "bubble.left.and.bubble.right"
        case .plan: return "list.bullet.rectangle"
        case .ask: return "questionmark.circle"
        }
    }
}

// MARK: - Message Direction
/// 消息方向枚举
enum MessageDirection: String, Codable {
    case user = "user"           // 用户发送
    case agent = "agent"         // Agent 响应
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

// MARK: - Permission Type
/// 权限类型枚举
enum PermissionType: String, Codable, CaseIterable {
    case fileRead = "file_read"
    case fileWrite = "file_write"
    case terminalCreate = "terminal_create"
    case networkRequest = "network_request"

    var displayName: String {
        switch self {
        case .fileRead: return "读取文件"
        case .fileWrite: return "写入文件"
        case .terminalCreate: return "创建终端"
        case .networkRequest: return "网络请求"
        }
    }

    var icon: String {
        switch self {
        case .fileRead: return "doc.text"
        case .fileWrite: return "doc.badge.plus"
        case .terminalCreate: return "terminal"
        case .networkRequest: return "network"
        }
    }
}

// MARK: - Permission Decision
/// 权限决定枚举
enum PermissionDecision: String, Codable {
    case pending = "pending"
    case allowed = "allowed"
    case denied = "denied"
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

// MARK: - Auto Approve Policy
/// 自动批准策略枚举
enum AutoApprovePolicy: String, Codable, CaseIterable {
    case askAlways = "ask_always"           // 总是询问
    case approveReads = "approve_reads"     // 自动批准读操作
    case approveAll = "approve_all"         // 自动批准所有

    var displayName: String {
        switch self {
        case .askAlways: return "总是询问"
        case .approveReads: return "自动批准读操作"
        case .approveAll: return "自动批准所有"
        }
    }
}
