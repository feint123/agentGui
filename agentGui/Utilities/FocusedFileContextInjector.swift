//
//  FocusedFileContextInjector.swift
//  agentGui
//
// CV-FA2: 从 MessageAttachment(origin: .focused) 重建内联上下文文本，
// 供 API 消息构建层注入，保持 prompt 语义与旧格式一致。
//

import Foundation

enum FocusedFileContextInjector {

    /// 从单个 `.focused` 附件生成内联上下文字符串。
    /// 格式与 ChatView+Actions.sendMessage() 旧实现一致：
    ///   "当前文件: /path/file.swift[:line[-line]][\n选区内容:\n<text>]"
    static func contextString(from attachment: MessageAttachment) -> String {
        var result = "当前文件: " + attachment.filePath

        if let start = attachment.lineStart, let end = attachment.lineEnd {
            if start == end {
                result += ":\(start)"
            } else {
                result += ":\(start)-\(end)"
            }
        }

        if let sel = attachment.selectedText, !sel.isEmpty {
            result += "\n选区内容:\n\(sel)"
        }

        return result
    }

    /// 将 attachments 中第一个 `.focused` 附件的上下文注入到 messageText 前面。
    ///
    /// - 如果 messageText 已有 "当前文件:" 前缀（旧消息），不重复注入。
    /// - 如果没有 `.focused` 附件，原样返回。
    static func inject(into messageText: String, from attachments: [MessageAttachment]) -> String {
        guard let focused = attachments.first(where: { $0.origin == .focused }) else {
            return messageText
        }

        // 旧消息已内联上下文 → 不重复注入
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("当前文件:") || trimmed.hasPrefix("当前选区:") {
            return messageText
        }

        let ctx = contextString(from: focused)
        return ctx + "\n\n" + messageText
    }
}
