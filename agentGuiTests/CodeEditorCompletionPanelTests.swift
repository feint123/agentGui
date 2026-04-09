import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorCompletionPanelTests {
    @Test
    func selectNextEmitsSingleSelectionChangeNotification() {
        let panel = CodeEditorCompletionPanel()
        panel.update(
            session: CodeEditorCompletionSession(
                cursorOffset: 0,
                prefixWord: "",
                items: [
                    CodeEditorCompletionItem(label: "alpha"),
                    CodeEditorCompletionItem(label: "beta")
                ],
                selectedIndex: 0,
                isLoading: false
            )
        )

        let tableView = try! #require(findTableView(in: panel.panel.contentView))
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTableView.selectionDidChangeNotification,
            object: tableView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        panel.selectNext()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        #expect(notificationCount == 1)
        #expect(panel.acceptSelectedItem()?.label == "beta")
    }

    @Test
    func outOfBoundsTableRowReturnsNil() {
        let panel = CodeEditorCompletionPanel()
        panel.update(
            session: CodeEditorCompletionSession(
                cursorOffset: 0,
                prefixWord: "",
                items: [CodeEditorCompletionItem(label: "alpha")],
                selectedIndex: 0,
                isLoading: false
            )
        )

        let tableView = try! #require(findTableView(in: panel.panel.contentView))
        #expect(panel.tableView(tableView, viewFor: tableView.tableColumns.first, row: 5) == nil)
    }
}

@MainActor
private func findTableView(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let tableView = view as? NSTableView {
        return tableView
    }
    for subview in view.subviews {
        if let tableView = findTableView(in: subview) {
            return tableView
        }
    }
    return nil
}