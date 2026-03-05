//
//  ACPAdapters.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import Foundation

/// ACP 类型到应用模型的适配器工具类
enum ACPAdapters {

    // MARK: - Session Mode Conversion

    /// 将 ACP Mode 转换为 SessionMode
    static func convertSessionMode(_ acpMode: String?) -> SessionMode {
        guard let acpMode = acpMode else { return .chat }
        switch acpMode.lowercased() {
        case "code": return .code
        case "chat": return .chat
        case "plan": return .plan
        case "ask": return .ask
        default: return .chat
        }
    }

    // MARK: - Message Direction Conversion

    /// 判断消息方向（用户 vs Agent）
    static func determineMessageDirection(isUser: Bool) -> MessageDirection {
        return isUser ? .user : .agent
    }

    // MARK: - Tool Kind Conversion

    /// 将 ACP ToolKind 转换为应用 ToolKind
    static func convertToolKind(_ acpToolKind: String?) -> ToolKind {
        guard let kind = acpToolKind else { return .other }
        switch kind.lowercased() {
        case "read": return .read
        case "edit": return .edit
        case "execute": return .execute
        case "search": return .search
        case "delete": return .delete
        case "think": return .think
        case "fetch": return .fetch
        case "plan": return .plan
        case "switchmode", "switch_mode": return .switchMode
        default: return .other
        }
    }

    // MARK: - Tool Status Conversion

    /// 将 ACP ToolCallStatus 转换为 ToolStatus
    static func convertToolStatus(_ status: String?) -> ToolStatus {
        guard let status = status else { return .inProgress }
        switch status.lowercased() {
        case "inprogress", "in_progress": return .inProgress
        case "success", "completed": return .success
        case "failed", "error": return .failed
        case "cancelled", "canceled": return .cancelled
        default: return .inProgress
        }
    }

    // MARK: - Stop Reason Conversion

    /// 判断消息是否完成
    static func isMessageComplete(_ stopReason: String?) -> Bool {
        guard let reason = stopReason else { return false }
        return ["endturn", "end_turn", "maxtokens", "max_tokens"].contains(reason.lowercased())
    }

    // MARK: - Permission Type Conversion

    /// 将 ACP 权限请求类型转换为 PermissionType
    static func convertPermissionType(_ requestType: String?) -> PermissionType {
        guard let type = requestType?.lowercased() else { return .fileRead }
        if type.contains("file") && type.contains("write") {
            return .fileWrite
        } else if type.contains("file") {
            return .fileRead
        } else if type.contains("terminal") {
            return .terminalCreate
        } else if type.contains("network") {
            return .networkRequest
        }
        return .fileRead
    }

    // MARK: - Diff Formatting

    /// 格式化 diff 内容用于显示
    static func formatDiff(_ diff: String?) -> String {
        guard let diff = diff, !diff.isEmpty else { return "" }

        // 简单的 diff 格式化：按行分割并添加基本颜色标记（可选）
        let lines = diff.components(separatedBy: .newlines)
        var formatted = ""

        for line in lines {
            if line.hasPrefix("+") {
                // 添加行（绿色）
                formatted += line + "\n"
            } else if line.hasPrefix("-") {
                // 删除行（红色）
                formatted += line + "\n"
            } else {
                // 上下文行
                formatted += line + "\n"
            }
        }

        return formatted
    }

    // MARK: - Time Formatting

    /// 格式化时间戳
    static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    /// 格式化持续时间
    static func formatDuration(_ startTime: Date?, endTime: Date? = nil) -> String {
        guard let start = startTime else { return "" }
        let end = endTime ?? Date()
        let duration = end.timeIntervalSince(start)

        if duration < 60 {
            return "\(Int(duration))秒"
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            return "\(minutes)分钟"
        } else {
            let hours = Int(duration / 3600)
            let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)小时\(minutes)分钟"
        }
    }

    // MARK: - File Path Formatting

    /// 缩短文件路径用于显示
    static func shortenPath(_ path: String, maxLength: Int = 30) -> String {
        if path.count <= maxLength { return path }

        let components = (path as NSString).pathComponents
        if components.count > 2 {
            let filename = components.last ?? ""
            let parent = components[components.count - 2]
            return "\(parent)/../\(filename)"
        }

        return "...\(path.suffix(maxLength - 3))"
    }

    /// 获取文件名
    static func fileName(from path: String?) -> String {
        guard let path = path else { return "" }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Error Formatting

    /// 格式化错误信息用于显示
    static func formatError(_ error: Error) -> String {
        if let agentError = error as? AgentClientError {
            return agentError.description
        }

        let nsError = error as NSError
        return nsError.localizedDescription.isEmpty ? "未知错误" : nsError.localizedDescription
    }
}
