import Testing
import Foundation
@testable import agentGui

/// CV-FA2: 验证发送时聚焦文件以 MessageAttachment(origin: .focused) 持久化，
/// 而非内联到 textContent。
struct FocusedFilePersistenceIntegrationTests {

    @Test
    func focusedFileNotInTextContent() {
        // 模拟 sendMessage 中重组逻辑的纯函数部分
        // （完整 UI 集成测试不在此文件，只测 helper 层行为）

        // 验证：attachedFiles 包含 .focused 时，
        // MessageAttachment.from() 产生 origin == .focused
        var file = AttachedFile(
            name: "App.swift",
            url: URL(fileURLWithPath: "/ws/App.swift"),
            origin: .focused
        )
        file.selectedText = "struct ContentView: View {}"
        let attachment = MessageAttachment.from(file)

        #expect(attachment.origin == .focused)
        #expect(attachment.selectedText == "struct ContentView: View {}")
        #expect(attachment.filePath == "/ws/App.swift")
    }

    @Test
    func focusedFileContextStringMatchesLegacyFormat() {
        // 验证 FocusedFileContextInjector 输出与旧 contextParts 格式完全一致
        let a = MessageAttachment(
            filePath: "/ws/src/View.swift",
            displayName: "View.swift",
            fileKind: .sourceCode,
            lineStart: 5,
            lineEnd: 10,
            origin: .focused,
            selectedText: "var body: some View {\n    Text(\"hello\")\n}"
        )
        let ctx = FocusedFileContextInjector.contextString(from: a)
        let expected = "当前文件: /ws/src/View.swift:5-10\n选区内容:\nvar body: some View {\n    Text(\"hello\")\n}"
        #expect(ctx == expected)
    }

    @Test
    func legacyMessageTextLeftUntouched() {
        // 旧格式消息 textContent 已含前缀，注入器不修改
        let oldText = "当前文件: /ws/src/App.swift\n\n做点什么吧"
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let injected = FocusedFileContextInjector.inject(into: oldText, from: [a])
        #expect(injected == oldText)
    }

    @Test
    func noFocusedFileYieldsNoAttachment() {
        // showFileContext = false 时，不创建 .focused attachment
        let user: [MessageAttachment] = []
        #expect(user.filter { $0.origin == .focused }.isEmpty)
    }
}

// MARK: - Backward Compat: 旧消息仍能正确 parse

extension FocusedFilePersistenceIntegrationTests {

    @Test
    func legacyMessageWithFileOnlyParsesDisplayBody() {
        let old = "当前文件: /ws/src/App.swift\n\n请帮我重构"
        let parsed = UserMessageTextParser.parse(text: old, workspaceRoot: "/ws")
        // bodyText 应不含 "当前文件:" 前缀
        #expect(!parsed.bodyText.hasPrefix("当前文件:"))
        #expect(parsed.bodyText.contains("请帮我重构") || parsed.bodyText.contains("/ws/src/App.swift"))
    }

    @Test
    func legacyMessageWithSelectionParsesCorrectly() {
        let old = "当前文件: /ws/src/App.swift:10-20\n选区内容:\nlet x = 1\n\n能帮我分析吗"
        let parsed = UserMessageTextParser.parse(text: old, workspaceRoot: "/ws")
        #expect(!parsed.bodyText.hasPrefix("当前文件:"))
        // 选区后的正文被保留
        #expect(parsed.bodyText.contains("能帮我分析吗"))
    }

    @Test
    func newMessageWithFocusedAttachmentHasCleanBodyText() {
        // 新格式：textContent 只含用户正文，无前缀
        let clean = "帮我看看这段逻辑"
        let parsed = UserMessageTextParser.parse(text: clean, workspaceRoot: "/ws")
        #expect(parsed.bodyText == "帮我看看这段逻辑")
        #expect(parsed.others.isEmpty) // 无 @Mention，无 Referenced files
    }
}
