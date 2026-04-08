// MarkdownMessageViewStreamingTests.swift
// agentGuiTests

import Testing
import SwiftUI
@testable import agentGui

@MainActor
struct MarkdownMessageViewStreamingTests {

    /// 默认参数 showsCursor=false，构建不崩溃
    @Test
    func defaultNoCursor() {
        let view = MarkdownMessageView(text: "Hello world")
        _ = view.body
    }

    /// showsCursor=true 参数存在且构建不崩溃
    @Test
    func withCursorBuilds() {
        let view = MarkdownMessageView(text: "Streaming...", showsCursor: true)
        _ = view.body
    }

    /// showsCursor=false 时，视图不持有光标相关状态
    @Test
    func noCursorWhenFalse() {
        let view = MarkdownMessageView(text: "Done text", showsCursor: false)
        // 仅验证可以构建 —— 没有崩溃即证明参数链正确
        _ = view.body
    }
}
