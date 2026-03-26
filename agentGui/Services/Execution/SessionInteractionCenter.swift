import Foundation
import Observation

@Observable
@MainActor
final class SessionInteractionCenter {
    private(set) var userQuestionsBySessionID: [String: AskUserQuestionRequest] = [:]

    func publishUserQuestion(_ request: AskUserQuestionRequest, for sessionID: String) {
        userQuestionsBySessionID[sessionID] = request
    }

    func userQuestion(for sessionID: String) -> AskUserQuestionRequest? {
        userQuestionsBySessionID[sessionID]
    }

    func clearUserQuestion(for sessionID: String) {
        userQuestionsBySessionID.removeValue(forKey: sessionID)
    }
}