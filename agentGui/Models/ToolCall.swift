//
//  ToolCall.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftData
import Foundation

@Model
final class ToolCall {
    /// 唯一标识符
    var id: UUID

    /// 工具调用 ID (来自 ACP)
    var toolCallId: String

    /// 工具类型
    var kind: ToolKind

    /// 显示标题
    var title: String?

    /// 状态
    var status: ToolStatus

    /// 关联的文件路径
    var filePath: String?

    /// Diff 内容 (用于编辑操作)
    var diffContent: String?

    /// 终端输出
    var terminalOutput: String?

    /// 开始时间
    var startTime: Date?

    /// 结束时间
    var endTime: Date?

    /// 关联的消息
    var message: Message?

    init(
        toolCallId: String,
        kind: ToolKind,
        message: Message
    ) {
        self.id = UUID()
        self.toolCallId = toolCallId
        self.kind = kind
        self.status = .inProgress
        self.title = nil
        self.filePath = nil
        self.diffContent = nil
        self.terminalOutput = nil
        self.startTime = Date()
        self.endTime = nil
        self.message = message
    }
}

// MARK: - Computed Properties
extension ToolCall {
    /// 是否进行中
    var isInProgress: Bool {
        status == .inProgress
    }

    /// 是否成功
    var isSuccess: Bool {
        status == .success
    }

    /// 是否失败
    var isFailed: Bool {
        status == .failed
    }

    /// 执行时长（秒）
    var duration: TimeInterval? {
        guard let start = startTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }

    /// 格式化的状态显示
    var statusDisplay: String {
        return status.displayName
    }

    /// 格式化的文件路径（截短显示）
    var displayPath: String? {
        guard let path = filePath else { return nil }
        let components = path.components(separatedBy: "/")
        if components.count > 3 {
            return ".../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }

    /// 文件名
    var fileName: String? {
        guard let path = filePath else { return nil }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - Factory Methods
extension ToolCall {
    /// 创建文件读取工具调用
    static func readFileCall(toolCallId: String, filePath: String, message: Message) -> ToolCall {
        let toolCall = ToolCall(toolCallId: toolCallId, kind: .read, message: message)
        toolCall.title = "读取文件"
        toolCall.filePath = filePath
        return toolCall
    }

    /// 创建文件编辑工具调用
    static func editFileCall(toolCallId: String, filePath: String, diff: String, message: Message) -> ToolCall {
        let toolCall = ToolCall(toolCallId: toolCallId, kind: .edit, message: message)
        toolCall.title = "编辑文件"
        toolCall.filePath = filePath
        toolCall.diffContent = diff
        return toolCall
    }

    /// 创建终端执行工具调用
    static func terminalCall(toolCallId: String, command: String, message: Message) -> ToolCall {
        let toolCall = ToolCall(toolCallId: toolCallId, kind: .execute, message: message)
        toolCall.title = "执行命令"
        return toolCall
    }
}
