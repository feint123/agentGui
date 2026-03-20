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
    case askUser = "ask_user"
    case subagent = "subagent"
    case todo = "todo"
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
        case .askUser: return "questionmark.circle"
        case .subagent: return "person.badge.plus"
        case .todo: return "checklist"
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
        case .askUser: return "提问用户"
        case .subagent: return "子代理"
        case .todo: return "任务列表"
        case .other: return "其他"
        }
    }

    static func classify(rawName: String?, command rawCommand: String? = nil) -> ToolKind {
        if let command = rawCommand?.normalizedToolToken {
            switch command {
            case "view", "read", "open", "cat", "show", "read_file", "read_tool_payload", "read_pdf", "view_image", "read_pdf_tool":
                return .read
            case "str_replace", "create", "create_file", "write", "write_file", "insert", "append", "prepend", "replace", "edit", "apply_patch", "patch":
                return .edit
            case "delete", "remove", "delete_file", "unlink", "rm":
                return .delete
            default:
                break
            }
        }

        guard let normalized = rawName?.normalizedToolToken, !normalized.isEmpty else {
            return .other
        }

        switch normalized {
        case "read", "view", "open", "read_file", "open_file", "view_file", "read_tool_payload", "read_pdf", "view_image", "analyze_image":
            return .read
        case "edit", "write", "create", "insert", "patch", "apply_patch", "create_file", "write_file", "str_replace", "str_replace_based_edit_tool", "str_replace_editor", "insert_text", "update_file", "replace_text":
            return .edit
        case "execute", "exec", "bash", "shell", "command", "code_execution", "run_in_terminal", "run_task", "create_and_run_task":
            return .execute
        case "search", "semantic_search", "file_search", "grep_search", "web_search", "search_subagent", "github_repo", "vscode_listcodeusages":
            return .search
        case "fetch", "web_fetch", "fetch_webpage", "open_browser_page":
            return .fetch
        case "delete", "remove", "delete_file", "unlink", "rm":
            return .delete
        case "think", "thinking", "reason":
            return .think
        case "plan", "planner":
            return .plan
        case "switch_mode", "switchmode":
            return .switchMode
        case "ask_user", "ask_user_question", "vscode_askquestions":
            return .askUser
        case "subagent", "run_subagent":
            return .subagent
        case "todo", "update_todo_list", "manage_todo_list":
            return .todo
        default:
            break
        }

        if normalized.contains("search") {
            return .search
        }
        if normalized.contains("fetch") {
            return .fetch
        }
        if normalized.contains("read") || normalized.contains("view") || normalized.contains("open_file") {
            return .read
        }
        if normalized.contains("write") || normalized.contains("edit") || normalized.contains("patch") || normalized.contains("replace") || normalized.contains("insert") {
            return .edit
        }
        if normalized.contains("delete") || normalized.contains("remove") {
            return .delete
        }
        if normalized.contains("terminal") || normalized.contains("command") || normalized.contains("exec") || normalized.contains("bash") {
            return .execute
        }
        if normalized.contains("question") || normalized.contains("ask") {
            return .askUser
        }
        if normalized.contains("subagent") {
            return .subagent
        }
        if normalized.contains("todo") {
            return .todo
        }

        return ToolKind(rawValue: normalized) ?? .other
    }
}

// MARK: - Tool Result Status
/// 工具执行结果的语义状态，供 ToolExecutionResult 携带并传递给调用侧。
enum ToolResultStatus: Equatable {
    /// 执行成功，结果可信
    case success
    /// 执行失败（非重试类），如文件未找到、参数校验失败
    case failure
    /// 瞬时失败，可以重试（网络抖动、子进程崩溃等）
    case retryableFailure
    /// 命令或请求超时
    case timeout
    /// 操作系统或沙盒权限拒绝
    case permissionDenied
    /// 模型输入缺少必需参数
    case missingParameter
    /// 输入 JSON 或参数值无法解析
    case parseError
    /// 工具名称未注册
    case unknownTool
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

    static func normalizedACPStatus(from rawValue: String?) -> ToolStatus? {
        guard let normalized = rawValue?.normalizedToolToken, !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "in_progress", "running", "started", "pending", "working", "executing":
            return .inProgress
        case "success", "succeeded", "successful", "completed", "complete", "done", "finished", "ok":
            return .success
        case "failed", "failure", "error", "errored", "timed_out", "timeout":
            return .failed
        case "cancelled", "canceled", "aborted", "rejected", "denied", "stopped":
            return .cancelled
        default:
            return ToolStatus(rawValue: normalized)
        }
    }
}

private extension String {
    var normalizedToolToken: String {
        components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .lowercased()
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
