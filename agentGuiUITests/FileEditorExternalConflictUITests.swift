import XCTest

final class FileEditorExternalConflictUITests: UITestBase {

    @MainActor
    func testExternalWriteWithUnsavedEditsShowsConflictAndReloadsFromDisk() throws {
        let fixture = try makeWorkspaceFixture(initialText: "Before external update")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path
        ])
        dismissOnboardingIfPresent()

        let fileRow = app.staticTexts[fixture.fileURL.lastPathComponent]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 3))
        fileRow.click()

        let editor = app.textViews["blockEditor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText(" local draft")

        try "Disk replacement".write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(app.staticTexts["磁盘版本已变化，本地也有未保存修改。"].waitForExistence(timeout: 5))
        app.buttons["重新加载"].click()

        XCTAssertTrue(app.staticTexts["Disk replacement"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testExternalWriteWithUnsavedEditsCanKeepLocalDraft() throws {
        let fixture = try makeWorkspaceFixture(initialText: "Before external update")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path
        ])
        dismissOnboardingIfPresent()

        let fileRow = app.staticTexts[fixture.fileURL.lastPathComponent]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 3))
        fileRow.click()

        let editor = app.textViews["blockEditor.textView"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.click()
        editor.typeText(" local draft")

        try "Disk replacement".write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(app.staticTexts["磁盘版本已变化，本地也有未保存修改。"].waitForExistence(timeout: 5))
        app.buttons["保留当前编辑"].click()

        XCTAssertFalse(app.staticTexts["磁盘版本已变化，本地也有未保存修改。"].exists)

        try "Disk replacement again".write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(app.staticTexts["磁盘版本已变化，本地也有未保存修改。"].waitForExistence(timeout: 5))
    }

    private func makeWorkspaceFixture(initialText: String) throws -> (rootURL: URL, fileURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-ui-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("ConflictFixture.md")
        try initialText.write(to: fileURL, atomically: true, encoding: .utf8)
        return (rootURL, fileURL)
    }

}