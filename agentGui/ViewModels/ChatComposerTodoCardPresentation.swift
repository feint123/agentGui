import CoreGraphics
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
    let showsScrollContainer: Bool
    let maxListHeight: CGFloat?

    static func build(items: [TodoItem], maxVisibleItems: Int = 4) -> ChatComposerTodoCardPresentation {
        let prioritizedItems = items.sorted(by: sortItems)
        let doneCount = items.filter { $0.status == .done }.count
        let showsScrollContainer = items.count > maxVisibleItems

        return ChatComposerTodoCardPresentation(
            title: "任务列表",
            progressText: "\(doneCount)/\(items.count)",
            visibleItems: prioritizedItems,
            hiddenCount: 0,
            isVisible: !items.isEmpty,
            showsScrollContainer: showsScrollContainer,
            maxListHeight: showsScrollContainer ? 220 : nil
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
