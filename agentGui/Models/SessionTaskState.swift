import Foundation
import SwiftData

@Model
final class SessionTaskState {
    var sessionId: String
    var planJson: String
    var todoJson: String
    var verificationJson: String
    var updatedAt: Date

    init(
        sessionId: String,
        planJson: String = "",
        todoJson: String = "[]",
        verificationJson: String = "",
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.planJson = planJson
        self.todoJson = todoJson
        self.verificationJson = verificationJson
        self.updatedAt = updatedAt
    }
}

extension SessionTaskState {
    var plan: ExecutionPlan? {
        guard !planJson.isEmpty, let data = planJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutionPlan.self, from: data)
    }

    var todoItems: [TodoItem] {
        guard let data = todoJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
    }

    var verification: CompletionVerification? {
        guard !verificationJson.isEmpty, let data = verificationJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CompletionVerification.self, from: data)
    }
}