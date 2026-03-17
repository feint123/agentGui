import XCTest

final class FileEditorInitialLoadDirtyStateUITests: UITestBase {

    @MainActor
    func testFirstOpenDoesNotMarkFileDirty() throws {
        let fixture = try makeWorkspaceFixture(initialText: "Before external update\n")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        launchApp(arguments: [
            "-com.agentgui.test.workingDirectory", fixture.rootURL.path
        ])
        dismissOnboardingIfPresent()

        let fileRow = app.staticTexts[fixture.fileURL.lastPathComponent]
        XCTAssertTrue(fileRow.waitForExistence(timeout: 3))
        fileRow.click()

        XCTAssertTrue(app.staticTexts["clean"].waitForExistence(timeout: 3))
    }

    private func makeWorkspaceFixture(initialText: String) throws -> (rootURL: URL, fileURL: URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgui-ui-dirty-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("DirtyStateFixture.md")
        try initialText.write(to: fileURL, atomically: true, encoding: .utf8)
        return (rootURL, fileURL)
    }
}