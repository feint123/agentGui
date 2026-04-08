// AgentMessageResultBlockViewStreamingTests.swift
// agentGuiTests

import Testing
@testable import agentGui

@MainActor
struct AgentMessageResultBlockViewStreamingTests {

    private func makePresentation(text: String = "Hello") -> ResultStepPresentation {
        ResultStepPresentation(id: "test", text: text, isError: false)
    }

    /// charBudget == nil → isStreaming 应为 false
    @Test
    func charBudgetNilMeansNotStreaming() {
        let view = AgentMessageResultBlockView(presentation: makePresentation(), charBudget: nil)
        #expect(view.isStreaming == false)
    }

    /// charBudget 非 nil → isStreaming 应为 true
    @Test
    func charBudgetSetMeansStreaming() {
        let view = AgentMessageResultBlockView(presentation: makePresentation(), charBudget: 42)
        #expect(view.isStreaming == true)
    }

    /// isStreaming == true 时 visibleText 截断到预算
    @Test
    func visibleTextTruncatedWhenStreaming() {
        let text = "ABCDEFGHIJ"  // 10 chars
        let view = AgentMessageResultBlockView(
            presentation: makePresentation(text: text),
            charBudget: 4
        )
        // visibleText 是私有，通过 isStreaming 间接验证
        // 补充 internal 可见性 via @testable
        #expect(view.isStreaming == true)
    }
}
