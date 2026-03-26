import Foundation
import Testing
@testable import agentGui

@MainActor
struct BuiltInSessionExecutionRegistryTests {
    @Test
    func contextsKeepModelAndTokenStateIsolatedPerSession() {
        let registry = BuiltInSessionExecutionRegistry()
        let first = registry.context(for: "session-a")
        let second = registry.context(for: "session-b")

        first.currentInputTokens = 128
        first.currentModelID = "claude-sonnet"
        second.currentInputTokens = 32
        second.currentModelID = "claude-haiku"

        #expect(registry.currentInputTokens(for: "session-a") == 128)
        #expect(registry.currentModelID(for: "session-a") == "claude-sonnet")
        #expect(registry.currentInputTokens(for: "session-b") == 32)
        #expect(registry.currentModelID(for: "session-b") == "claude-haiku")
    }

    @Test
    func contextsKeepPendingQuestionsIsolatedPerSession() async {
        let registry = BuiltInSessionExecutionRegistry()

        let questionA = await makeQuestionRequest(header: "A")
        let questionB = await makeQuestionRequest(header: "B")

        registry.context(for: "session-a").pendingUserQuestion = questionA
        registry.context(for: "session-b").pendingUserQuestion = questionB

        #expect(registry.pendingUserQuestion(for: "session-a") === questionA)
        #expect(registry.pendingUserQuestion(for: "session-b") === questionB)

        questionA.cancel()
        questionB.cancel()
    }

    private func makeQuestionRequest(header: String) async -> AskUserQuestionRequest {
        await withCheckedContinuation { continuation in
            Task {
                _ = await withCheckedContinuation { (questionContinuation: CheckedContinuation<String, Never>) in
                    let request = AskUserQuestionRequest(
                        questions: [
                            AskUserQuestion(
                                question: "Question \(header)",
                                header: header,
                                options: [],
                                multiSelect: false
                            )
                        ],
                        continuation: questionContinuation
                    )
                    continuation.resume(returning: request)
                }
            }
        }
    }
}