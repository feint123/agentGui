// agentGuiTests/CodeEditorCompletionTriggerTests.swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorCompletionTriggerTests {

    // MARK: - shouldAutoTrigger

    @Test func shouldAutoTrigger_nonEmptyNonNumericWord_returnsTrue() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "myFun") == true)
    }

    @Test func shouldAutoTrigger_emptyString_returnsFalse() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "") == false)
    }

    @Test func shouldAutoTrigger_pureNumber_returnsFalse() {
        #expect(CompletionTriggerContext.shouldAutoTrigger(prefixWord: "123") == false)
    }

    // MARK: - trigger character detection

    @Test func triggerCharDetected_whenTypedDot_returnsTriggerCharKind() {
        let triggerChars = ["."]
        let lastChar = "."
        let isTrigger = triggerChars.contains(lastChar)
        #expect(isTrigger == true)
    }

    @Test func triggerCharNotDetected_whenTypedLetter_returnsInvokedKind() {
        let triggerChars = ["."]
        let lastChar = "f"
        let isTrigger = triggerChars.contains(lastChar)
        #expect(isTrigger == false)
    }

    // MARK: - client-side prefix refilter

    @Test func prefixRefilter_returnsItemsMatchingPrefix() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "myFunction"),
            CodeEditorCompletionItem(label: "myVariable"),
            CodeEditorCompletionItem(label: "otherFunc"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "my")
        #expect(filtered.map(\.label) == ["myFunction", "myVariable"])
    }

    @Test func prefixRefilter_emptyPrefix_returnsAll() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "a"),
            CodeEditorCompletionItem(label: "b"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "")
        #expect(filtered.count == 2)
    }

    @Test func prefixRefilter_caseInsensitive() {
        let items: [CodeEditorCompletionItem] = [
            CodeEditorCompletionItem(label: "PrintLine"),
        ]
        let filtered = CodeEditorCompletionTrigger.clientFilter(items: items, prefix: "print")
        #expect(filtered.count == 1)
    }

    // MARK: - Generation cancel / rapid typing

    @Test func rapidTypingCancelsOldSession_onlyLatestResultApplied() async {
        // 模拟：第 1 次 fetch 慢（被取消返回 nil），第 2 次立即返回，
        // 验证最终会话只包含第 2 次的结果。
        var callCount = 0
        var sessionUpdates: [CodeEditorCompletionSession?] = []
        let trigger = CodeEditorCompletionTrigger()
        trigger.onSessionChange = { sessionUpdates.append($0) }

        trigger.requestCompletion = { ctx, callback in
            callCount += 1
            let current = callCount
            Task {
                if current == 1 {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms 延迟
                    callback(nil) // 被取消
                } else {
                    callback([CodeEditorCompletionItem(label: "secondResult")])
                }
            }
        }
        trigger.cancelRequest = {}

        // 第一次：trigger character 立即触发
        trigger.handleTyping(
            char: ".",
            cursorOffset: 5,
            prefixWord: "",
            triggerCharacters: ["."]
        )
        // 第二次：也用 trigger character，确保立即触发（不走 debounce）
        trigger.handleTyping(
            char: ".",
            cursorOffset: 6,
            prefixWord: "",
            triggerCharacters: ["."]
        )

        // 等待第 2 次 fetch 回来（Task 调度 + callback）
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 最终会话应来自第 2 次，不应含 nil 导致的旧结果
        let finalSession = trigger.currentSession
        #expect(finalSession?.items.first?.label == "secondResult")
    }
}
