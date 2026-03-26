import Testing
@testable import agentGui

@MainActor
struct SessionInteractionCenterTests {
    @Test
    func publishUserQuestionStoresRequestBySession() async {
        let center = SessionInteractionCenter()
        let request = await makeQuestionRequest(header: "Session A")

        center.publishUserQuestion(request, for: "session-a")

        #expect(center.userQuestion(for: "session-a") === request)
        #expect(center.userQuestion(for: "session-b") == nil)

        request.cancel()
    }

    @Test
    func clearUserQuestionRemovesOnlyTargetSession() async {
        let center = SessionInteractionCenter()
        let first = await makeQuestionRequest(header: "A")
        let second = await makeQuestionRequest(header: "B")

        center.publishUserQuestion(first, for: "session-a")
        center.publishUserQuestion(second, for: "session-b")
        center.clearUserQuestion(for: "session-a")

        #expect(center.userQuestion(for: "session-a") == nil)
        #expect(center.userQuestion(for: "session-b") === second)

        first.cancel()
        second.cancel()
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