import Foundation
import Testing
@testable import agentGui

@MainActor
struct ChatComposerTodoCardPresentationTests {

    @Test func buildReturnsInvisiblePresentationForEmptyItems() async throws {
        let presentation = ChatComposerTodoCardPresentation.build(items: [], maxVisibleItems: 4)

        #expect(!presentation.isVisible)
        #expect(presentation.visibleItems.isEmpty)
        #expect(presentation.progressText == "0/0")
        #expect(presentation.hiddenCount == 0)
    }

    @Test func buildPrioritizesInProgressAndPendingItemsBeforeCompletedItems() async throws {
        let items = [
            TodoItem(id: "1", title: "done", status: .done),
            TodoItem(id: "2", title: "doing", status: .inProgress),
            TodoItem(id: "3", title: "pending", status: .pending),
            TodoItem(id: "4", title: "pending-2", status: .pending),
            TodoItem(id: "5", title: "done-2", status: .done)
        ]

        let presentation = ChatComposerTodoCardPresentation.build(items: items, maxVisibleItems: 3)

        #expect(presentation.isVisible)
        #expect(presentation.progressText == "2/5")
        #expect(presentation.visibleItems.map(\.title) == ["doing", "pending", "pending-2", "done", "done-2"])
        #expect(presentation.hiddenCount == 0)
        #expect(presentation.showsScrollContainer)
    }

    @Test func buildKeepsCancelledItemsAfterActiveItems() async throws {
        let items = [
            TodoItem(id: "1", title: "cancelled", status: .cancelled),
            TodoItem(id: "2", title: "pending", status: .pending),
            TodoItem(id: "3", title: "done", status: .done)
        ]

        let presentation = ChatComposerTodoCardPresentation.build(items: items, maxVisibleItems: 5)

        #expect(presentation.visibleItems.map(\.title) == ["pending", "done", "cancelled"])
        #expect(!presentation.showsScrollContainer)
    }

    @Test func buildEnablesScrollOnlyWhenItemCountExceedsThreshold() async throws {
        let items = [
            TodoItem(id: "1", title: "one", status: .pending),
            TodoItem(id: "2", title: "two", status: .pending),
            TodoItem(id: "3", title: "three", status: .pending),
            TodoItem(id: "4", title: "four", status: .pending)
        ]

        let presentation = ChatComposerTodoCardPresentation.build(items: items, maxVisibleItems: 4)

        #expect(!presentation.showsScrollContainer)
        #expect(presentation.maxListHeight == nil)
    }

    @Test func assistSurfacePrefersSlashOverTodo() async throws {
        let presentation = ChatComposerTodoCardPresentation.build(
            items: [TodoItem(id: "1", title: "doing", status: .inProgress)],
            maxVisibleItems: 4
        )

        let surface = ChatComposerAssistSurface.resolve(
            slashQuery: "brain",
            hasMentionCandidates: false,
            mentionQuery: nil,
            todoPresentation: presentation
        )

        #expect(surface == .slash)
    }

    @Test func assistSurfacePrefersMentionOverTodo() async throws {
        let presentation = ChatComposerTodoCardPresentation.build(
            items: [TodoItem(id: "1", title: "doing", status: .inProgress)],
            maxVisibleItems: 4
        )

        let surface = ChatComposerAssistSurface.resolve(
            slashQuery: nil,
            hasMentionCandidates: true,
            mentionQuery: "Rea",
            todoPresentation: presentation
        )

        #expect(surface == .mention)
    }

    @Test func assistSurfaceShowsTodoWhenNoHigherPriorityAssistIsActive() async throws {
        let presentation = ChatComposerTodoCardPresentation.build(
            items: [TodoItem(id: "1", title: "doing", status: .inProgress)],
            maxVisibleItems: 4
        )

        let surface = ChatComposerAssistSurface.resolve(
            slashQuery: nil,
            hasMentionCandidates: false,
            mentionQuery: nil,
            todoPresentation: presentation
        )

        #expect(surface == .todo)
    }
}