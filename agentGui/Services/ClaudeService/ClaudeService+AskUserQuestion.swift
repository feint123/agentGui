//
//  ClaudeService+AskUserQuestion.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

struct AskUserQuestionOption: Decodable {
    let label: String
    let description: String
}

struct AskUserQuestion: Decodable {
    let question: String
    let header: String
    let options: [AskUserQuestionOption]
    let multiSelect: Bool
}

final class AskUserQuestionRequest: Identifiable {
    let id = UUID()
    let questions: [AskUserQuestion]
    private let continuation: CheckedContinuation<String, Never>
    private var resolved = false

    init(questions: [AskUserQuestion], continuation: CheckedContinuation<String, Never>) {
        self.questions = questions
        self.continuation = continuation
    }

    func submit(selections: [[String]]) {
        guard !resolved else { return }
        resolved = true
        let answers = zip(questions, selections).map { question, selected in
            [
                "question": question.question,
                "header": question.header,
                "selected": selected
            ] as [String: Any]
        }
        let payload: [String: Any] = ["answers": answers]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
        let result = String(data: data, encoding: .utf8) ?? "{\"answers\":[]}"
        continuation.resume(returning: result)
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: "{\"answers\":[]}")
    }
}

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

        let sessionID = activeBuiltInSessionID
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let request = AskUserQuestionRequest(
                questions: questions,
                continuation: continuation
            )
            self.publishPendingUserQuestion(request, for: sessionID)
        }
        clearPendingUserQuestion(for: sessionID)
        return result
    }
}
