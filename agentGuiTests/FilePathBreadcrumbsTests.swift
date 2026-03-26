import Foundation
import Testing
@testable import agentGui

struct FilePathBreadcrumbsTests {

    @Test func buildsWorkspaceRelativeBreadcrumbItems() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/Workspace")
        let fileURL = URL(fileURLWithPath: "/tmp/Workspace/Sources/Feature/FileEditorView.swift")

        let items = FilePathBreadcrumbs.makeItems(for: fileURL, relativeTo: workspaceURL)

        #expect(items.map(\.title) == ["Workspace", "Sources", "Feature", "FileEditorView.swift"])
        #expect(items.map(\.isCurrent) == [false, false, false, true])
        #expect(items.map(\.url?.path) == [
            "/tmp/Workspace",
            "/tmp/Workspace/Sources",
            "/tmp/Workspace/Sources/Feature",
            "/tmp/Workspace/Sources/Feature/FileEditorView.swift"
        ])
    }

    @Test func fallsBackToAbsolutePathWhenFileIsOutsideWorkspaceRoot() {
        let workspaceURL = URL(fileURLWithPath: "/tmp/Workspace")
        let externalFileURL = URL(fileURLWithPath: "/tmp/Elsewhere/Notes/Todo.md")

        let items = FilePathBreadcrumbs.makeItems(for: externalFileURL, relativeTo: workspaceURL)

        #expect(items.map(\.title) == ["tmp", "Elsewhere", "Notes", "Todo.md"])
        #expect(items.last?.isCurrent == true)
        #expect(items.last?.url?.path == "/tmp/Elsewhere/Notes/Todo.md")
    }
}