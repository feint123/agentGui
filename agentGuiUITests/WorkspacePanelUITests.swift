import XCTest

final class WorkspacePanelUITests: UITestBase {

    @MainActor
    func testWorkspaceTreeSurvivesTabSwitchAwayAndBack() throws {
        let fixture = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path,
            "-com.agentgui.test.preloadMessages", "false"
        ])

        let docsRow = app.staticTexts["DocsSeed"]
        XCTAssertTrue(docsRow.waitForExistence(timeout: 3))

        app.buttons["Skills"].click()
        app.buttons["对话"].click()

        XCTAssertTrue(docsRow.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["搜索文件或文件夹"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testWorkspaceSearchShowsEmptyStateForUnmatchedQuery() throws {
        let fixture = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path,
            "-com.agentgui.test.preloadMessages", "false"
        ])

        let searchField = app.textFields["搜索文件或文件夹"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.click()
        searchField.typeText("missing-entry")

        XCTAssertTrue(app.staticTexts["workspace.searchState.empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Notes.md"].exists)
    }

    @MainActor
    func testWorkspaceTreeSupportsCreateRenameDeleteFlow() throws {
        let fixture = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path,
            "-com.agentgui.test.preloadMessages", "false"
        ])

        let docsRow = app.staticTexts["DocsSeed"]
        XCTAssertTrue(docsRow.waitForExistence(timeout: 3))
        docsRow.click()

        let newFolderButton = app.buttons["新建文件夹"]
        XCTAssertTrue(newFolderButton.waitForExistence(timeout: 2))
        newFolderButton.click()
        XCTAssertFalse(app.textFields["workspace.prompt.textField"].exists)
        fillInlineEditor(with: "Drafts")
        XCTAssertTrue(app.staticTexts["Drafts"].waitForExistence(timeout: 3))

        let draftsRow = app.staticTexts["Drafts"]
        draftsRow.click()

        let newFileButton = app.buttons["新建文件"]
        XCTAssertTrue(newFileButton.waitForExistence(timeout: 2))
        newFileButton.click()
        fillInlineEditor(with: "Draft.md")
        XCTAssertTrue(app.staticTexts["Draft.md"].waitForExistence(timeout: 3))

        let draftFileRow = app.staticTexts["Draft.md"]
        draftFileRow.click()

        let renameButton = app.buttons["重命名"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 2))
        renameButton.click()
        fillInlineEditor(with: "DraftRenamed.md")
        XCTAssertTrue(app.staticTexts["DraftRenamed.md"].waitForExistence(timeout: 3))

        let renamedRow = app.staticTexts["DraftRenamed.md"]
        renamedRow.click()

        let deleteButton = app.buttons["删除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
        deleteButton.click()

        let confirmDeleteButton = app.dialogs.buttons["删除"].firstMatch
        XCTAssertTrue(confirmDeleteButton.waitForExistence(timeout: 2))
        confirmDeleteButton.click()

        XCTAssertTrue(waitForDisappearance(of: renamedRow, timeout: 3))
    }

    @MainActor
    func testInlineRenameCancelsWhenFocusMovesAway() throws {
        let fixture = try makeWorkspaceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path,
            "-com.agentgui.test.preloadMessages", "false"
        ])

        let docsRow = app.staticTexts["DocsSeed"]
        XCTAssertTrue(docsRow.waitForExistence(timeout: 3))
        docsRow.click()

        let renameButton = app.buttons["重命名"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 2))
        renameButton.click()

        let inlineEditor = inlineEditorField()
        XCTAssertTrue(inlineEditor.waitForExistence(timeout: 2))
        inlineEditor.click()
        inlineEditor.typeKey("a", modifierFlags: .command)
        inlineEditor.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        inlineEditor.typeText("BlurredName")

        let searchField = app.textFields["搜索文件或文件夹"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()

        XCTAssertTrue(waitForDisappearance(of: inlineEditor, timeout: 2))
        XCTAssertTrue(app.staticTexts["DocsSeed"].exists)
        XCTAssertFalse(app.staticTexts["BlurredName"].exists)
    }

    @MainActor
    private func fillInlineEditor(with text: String) {
        let textField = inlineEditorField()
        XCTAssertTrue(textField.waitForExistence(timeout: 2))
        textField.click()
        textField.typeKey("a", modifierFlags: .command)
        textField.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        textField.typeText(text)
        textField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func inlineEditorField() -> XCUIElement {
        if app.textFields["输入名称"].firstMatch.exists {
            return app.textFields["输入名称"].firstMatch
        }
        return app.textFields.element(boundBy: 1)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func makeWorkspaceFixture() throws -> (rootURL: URL, docsURL: URL, notesURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-ui-workspace-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("DocsSeed", isDirectory: true)
        let notesURL = rootURL.appendingPathComponent("Notes.md")

        try FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try "seed".write(to: notesURL, atomically: true, encoding: .utf8)

        return (rootURL, docsURL, notesURL)
    }
}