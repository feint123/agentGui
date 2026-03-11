import Foundation

enum ChatComposerAssistSurface: Equatable {
    case slash
    case mention
    case todo
    case none

    static func resolve(
        slashQuery: String?,
        hasMentionCandidates: Bool,
        mentionQuery: String?,
        todoPresentation: ChatComposerTodoCardPresentation
    ) -> ChatComposerAssistSurface {
        if slashQuery != nil {
            return .slash
        }
        if mentionQuery != nil, hasMentionCandidates {
            return .mention
        }
        if todoPresentation.isVisible {
            return .todo
        }
        return .none
    }
}

struct ChatComposerTodoCardPresentation: Equatable {
    let title: String
    let progressText: String
    let visibleItems: [TodoItem]
    let hiddenCount: Int
    let isVisible: Bool

    static func build(items: [TodoItem], maxVisibleItems: Int = 4) -> ChatComposerTodoCardPresentation {
        let prioritizedItems = items.sorted(by: sortItems)
        let visibleItems = Array(prioritizedItems.prefix(maxVisibleItems))
        let doneCount = items.filter { $0.status == .done }.count

        return ChatComposerTodoCardPresentation(
            title: "任务列表",
            progressText: "\(doneCount)/\(items.count)",
            visibleItems: visibleItems,
            hiddenCount: max(0, items.count - visibleItems.count),
            isVisible: !items.isEmpty
        )
    }

    private static func sortItems(lhs: TodoItem, rhs: TodoItem) -> Bool {
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func statusRank(_ status: TodoStatus) -> Int {
        switch status {
        case .inProgress:
            return 0
        case .pending:
            return 1
        case .done:
            return 2
        case .cancelled:
            return 3
        }
    }
}