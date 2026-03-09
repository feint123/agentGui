//
//  ClaudeService+AskUserQuestion.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

extension ClaudeService {

    // MARK: - Ask User Question

    func executeAskUserQuestion(input: MessageResponse.Content.Input) async -> String {
        // Parse the questions array from the DynamicContent input
        guard let questionsValue = input["questions"] else {
            return "{\"error\": \"missing 'questions' parameter\"}"
        }

        // DynamicContent is Decodable-only, so convert to Any via JSONSerialization
        let anyValue = dynamicContentToAny(questionsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let questions = try? JSONDecoder().decode([AskUserQuestion].self, from: data)
        else {
            return "{\"error\": \"failed to parse questions\"}"
        }

        // Suspend the agentic loop. ClaudeService is @MainActor so self.pendingUserQuestion
        // can be set directly without a Task wrapper.
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            self.pendingUserQuestion = AskUserQuestionRequest(
                questions: questions,
                continuation: continuation
            )
        }
        // Clear pending state now that the user has responded
        self.pendingUserQuestion = nil
        return result
    }
}
