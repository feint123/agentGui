import Testing
import Foundation
@testable import agentGui

struct FocusedFileContextInjectorTests {

    // MARK: - contextString(from:)

    @Test
    func contextStringWithPathOnly() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift")
    }

    @Test
    func contextStringWithLineRange() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 10,
            lineEnd: 25,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:10-25")
    }

    @Test
    func contextStringWithSingleLine() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 42,
            lineEnd: 42,
            origin: .focused
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:42")
    }

    @Test
    func contextStringWithSelectedText() {
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            lineStart: 10,
            lineEnd: 12,
            origin: .focused,
            selectedText: "let x = 42\nlet y = x"
        )
        let result = FocusedFileContextInjector.contextString(from: a)
        #expect(result == "当前文件: /ws/src/App.swift:10-12\n选区内容:\nlet x = 42\nlet y = x")
    }

    // MARK: - inject(into:focusedAttachments:)

    @Test
    func injectPrependsContextToMessageText() {
        let a = MessageAttachment(
            filePath: "/ws/src/View.swift",
            displayName: "View.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let result = FocusedFileContextInjector.inject(into: "帮我看看这段代码", from: [a])
        #expect(result == "当前文件: /ws/src/View.swift\n\n帮我看看这段代码")
    }

    @Test
    func injectNoOpWhenNoFocusedAttachments() {
        let external = MessageAttachment(
            filePath: "/ws/img/bg.png",
            displayName: "bg.png",
            fileKind: .image,
            origin: .external
        )
        let result = FocusedFileContextInjector.inject(into: "看图", from: [external])
        #expect(result == "看图")
    }

    @Test
    func injectSkipsNonFocusedAttachments() {
        let focused = MessageAttachment(
            filePath: "/ws/src/A.swift",
            displayName: "A.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let project = MessageAttachment(
            filePath: "/ws/src/B.swift",
            displayName: "B.swift",
            fileKind: .sourceCode,
            origin: .project
        )
        let result = FocusedFileContextInjector.inject(into: "你好", from: [focused, project])
        // 只有 focused 被注入
        #expect(result.contains("当前文件: /ws/src/A.swift"))
        #expect(!result.contains("/ws/src/B.swift"))
    }

    @Test
    func injectNoOpWhenTextAlreadyHasContextPrefix() {
        // 旧消息 textContent 已含前缀 → 不应重复注入
        let a = MessageAttachment(
            filePath: "/ws/src/App.swift",
            displayName: "App.swift",
            fileKind: .sourceCode,
            origin: .focused
        )
        let existingText = "当前文件: /ws/src/App.swift\n\n做点什么吧"
        let result = FocusedFileContextInjector.inject(into: existingText, from: [a])
        #expect(result == existingText)
    }

    @Test
    func injectHandlesEmptyAttachments() {
        let result = FocusedFileContextInjector.inject(into: "hello", from: [])
        #expect(result == "hello")
    }

    @Test
    func injectUsesFirstFocusedOnly() {
        let a1 = MessageAttachment(filePath: "/ws/a.swift", displayName: "a.swift",
                                   fileKind: .sourceCode, origin: .focused)
        let a2 = MessageAttachment(filePath: "/ws/b.swift", displayName: "b.swift",
                                   fileKind: .sourceCode, origin: .focused)
        let result = FocusedFileContextInjector.inject(into: "test", from: [a1, a2])
        // 只注入 a1
        #expect(result.contains("/ws/a.swift"))
        #expect(!result.contains("/ws/b.swift"))
    }
}
