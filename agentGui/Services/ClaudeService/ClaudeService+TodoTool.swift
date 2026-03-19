//
//  ClaudeService+TodoTool.swift
//  agentGui
//

import Foundation
import SwiftAnthropic
import SwiftData

extension ClaudeService {

    // MARK: - Update Todo List

    @discardableResult
    func executeUpdateTodoList(
        input: MessageResponse.Content.Input,
        sessionId: String,
        modelContext: ModelContext
    ) -> String {
        guard let itemsValue = input["items"] else {
            return "Error: missing 'items' parameter"
        }
        let anyValue = dynamicContentToAny(itemsValue)
        guard
            let arrayValue = anyValue as? [[String: Any]],
            let data = try? JSONSerialization.data(withJSONObject: arrayValue),
            let items = try? JSONDecoder().decode([TodoItem].self, from: data)
        else {
            return "Error: failed to parse 'items' array"
        }
        let store = SessionTaskStateStore(modelContext: modelContext)
        do {
            try store.saveTodoItems(items, for: sessionId)
            sessionTodoLists[sessionId] = items
        } catch {
            return "Error: failed to persist todo list"
        }
        return "Todo list updated with \(items.count) items."
    }
}
