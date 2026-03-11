import XCTest

final class FileEditorExternalRefreshUITests: UITestBase {

    @MainActor
    func testOpenFileRefreshesAfterExternalWrite() throws {
        let fixture = try makeWorkspaceFixture(initialText: "Before external update")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path
        ])

        let fileRow = app.staticTexts[fixture.fileURL.lastPathComponent]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 3))
        fileRow.click()

        XCTAssertTrue(app.staticTexts["Before external update"].waitForExistence(timeout: 3))

        try "After external update".write(to: fixture.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(app.staticTexts["After external update"].waitForExistence(timeout: 5))
    }

    private func makeWorkspaceFixture(initialText: String) throws -> (rootURL: URL, fileURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-ui-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("RefreshFixture.md")
        try initialText.write(to: fileURL, atomically: true, encoding: .utf8)
        return (rootURL, fileURL)
    }

}