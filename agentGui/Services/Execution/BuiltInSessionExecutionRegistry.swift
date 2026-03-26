import Foundation
import Observation

@Observable
@MainActor
final class BuiltInSessionExecutionContext {
    let sessionID: String
    var currentInputTokens: Int = 0
    var currentModelID: String = ""
    var pendingUserQuestion: AskUserQuestionRequest?

    init(sessionID: String) {
        self.sessionID = sessionID
    }
}

@Observable
@MainActor
final class BuiltInSessionExecutionRegistry {
    private(set) var contexts: [String: BuiltInSessionExecutionContext] = [:]

    func context(for sessionID: String) -> BuiltInSessionExecutionContext {
        if let context = contexts[sessionID] {
            return context
        }

        let context = BuiltInSessionExecutionContext(sessionID: sessionID)
        contexts[sessionID] = context
        return context
    }

    func currentInputTokens(for sessionID: String) -> Int {
        contexts[sessionID]?.currentInputTokens ?? 0
    }

    func currentModelID(for sessionID: String) -> String {
        contexts[sessionID]?.currentModelID ?? ""
    }

    func pendingUserQuestion(for sessionID: String) -> AskUserQuestionRequest? {
        contexts[sessionID]?.pendingUserQuestion
    }
}