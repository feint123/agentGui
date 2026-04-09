// agentGuiTests/CodeEditorSignatureHelpTriggerTests.swift
import Testing
@testable import agentGui

@Suite("CodeEditorSignatureHelpTrigger")
@MainActor
struct CodeEditorSignatureHelpTriggerTests {

    // MARK: - trigger char 立即触发

    @Test func triggerChar_whenDefault_firesRequest() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            callback(nil)
        }

        trigger.handleTyping(
            char: "(",
            cursorOffset: 10,
            triggerCharacters: ["(", ","],
            retriggerCharacters: [",", ")"]
        )
        // 触发去抖窗口后等待
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 1)
    }

    // MARK: - retrigger char 仅在 active 时触发

    @Test func retriggerChar_whenDefault_doesNotFire() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            callback(nil)
        }
        // "," 是 retrigger char，但当前是 default 状态
        trigger.handleTyping(
            char: ",",
            cursorOffset: 5,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 0)
    }

    @Test func retriggerChar_whenActive_fires() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var requestCount = 0
        // 第一次用 trigger char 激活
        trigger.requestSignatureHelp = { _, callback in
            requestCount += 1
            let sig = LSPSignatureInformation(
                label: "foo(a, b)", documentation: nil,
                parameters: [
                    LSPParameterInformation(label: .text("a"), documentation: nil),
                    LSPParameterInformation(label: .text("b"), documentation: nil)
                ],
                activeParameter: nil
            )
            callback(LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }
        trigger.handleTyping(
            char: "(",
            cursorOffset: 5,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 1)   // active 状态

        // 现在输入 ","（retrigger char）
        trigger.handleTyping(
            char: ",",
            cursorOffset: 6,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(requestCount == 2)
    }

    // MARK: - cancel

    @Test func cancel_whenActive_transitionsToDefault_firesNilSession() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var sessions: [LSPSignatureHelp?] = []
        trigger.onSessionChange = { sessions.append($0) }

        trigger.requestSignatureHelp = { _, callback in
            let sig = LSPSignatureInformation(
                label: "foo(a)", documentation: nil,
                parameters: [LSPParameterInformation(label: .text("a"), documentation: nil)],
                activeParameter: nil
            )
            callback(LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }

        trigger.handleTyping(
            char: "(",
            cursorOffset: 3,
            triggerCharacters: ["("],
            retriggerCharacters: [","]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(sessions.last??.isValid == true)

        trigger.cancel()
        #expect(sessions.isEmpty == false)
        #expect(sessions.last! == nil)
    }

    // MARK: - 代际仲裁：旧响应不覆盖新状态

    @Test func staleResponse_doesNotOverwriteNewerRequest() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var sessionUpdates: [LSPSignatureHelp?] = []
        trigger.onSessionChange = { sessionUpdates.append($0) }

        var callbacks: [((LSPSignatureHelp?) -> Void)] = []
        trigger.requestSignatureHelp = { _, cb in callbacks.append(cb) }

        // 使用 invoke(delay=0) 绕过去抖，让两个请求都发出
        trigger.invoke(cursorOffset: 3)   // generation 1
        trigger.invoke(cursorOffset: 4)   // generation 2

        // 两个 requestSignatureHelp 回调都已存储
        #expect(callbacks.count == 2)

        // 先回调 generation 1（stale）
        if callbacks.count >= 1 {
            let sig = LSPSignatureInformation(
                label: "stale()", documentation: nil, parameters: [], activeParameter: nil)
            callbacks[0](LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }
        // 再回调 generation 2（fresh）
        if callbacks.count >= 2 {
            let sig = LSPSignatureInformation(
                label: "fresh()", documentation: nil, parameters: [], activeParameter: nil)
            callbacks[1](LSPSignatureHelp(signatures: [sig], activeSignature: 0, activeParameter: 0))
        }

        // session 应该是 fresh，不是 stale
        let finalHelp = sessionUpdates.last.flatMap { $0 }
        #expect(finalHelp?.signatures[0].label == "fresh()")
    }

    // MARK: - overload 切换

    @Test func next_cyclesThroughSignatures() async {
        let trigger = CodeEditorSignatureHelpTrigger()
        var lastSession: LSPSignatureHelp?
        trigger.onSessionChange = { lastSession = $0 }

        trigger.requestSignatureHelp = { _, cb in
            let sigs = [
                LSPSignatureInformation(label: "foo(a)", documentation: nil,
                                        parameters: [], activeParameter: nil),
                LSPSignatureInformation(label: "foo(a, b)", documentation: nil,
                                        parameters: [], activeParameter: nil)
            ]
            cb(LSPSignatureHelp(signatures: sigs, activeSignature: 0, activeParameter: 0))
        }

        trigger.handleTyping(char: "(", cursorOffset: 3,
                             triggerCharacters: ["("], retriggerCharacters: [","])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(lastSession?.activeSignature == 0)

        trigger.next()
        #expect(lastSession?.activeSignature == 1)

        trigger.next()   // 到达末端，循环回 0
        #expect(lastSession?.activeSignature == 0)
    }
}
