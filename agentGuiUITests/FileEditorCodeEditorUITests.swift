import XCTest

final class FileEditorCodeEditorUITests: XCTestCase {
    private let filePath = "/Volumes/T7/文稿/Projects/agentGui/tmp/code-editor-feature1.txt"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try "".write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    func testTextFileUsesDedicatedCodeEditorPath() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.preloadApiKey", "true",
            "-com.agentgui.test.selectedFilePath", filePath
        ]

        app.launch()

        let codeEditor = app.textViews["codeEditor.textView"]
        XCTAssertTrue(codeEditor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["blockEditor.textView"].exists)

        let dirtyState = app.staticTexts["fileEditor.dirtyState"]
        XCTAssertTrue(dirtyState.waitForExistence(timeout: 5))
        XCTAssertEqual(dirtyState.label, "clean")

        codeEditor.click()
        codeEditor.typeText("hello world")

        XCTAssertTrue(waitForLabel(of: dirtyState, equals: "dirty", timeout: 5))

        let saveButton = app.buttons["fileEditor.saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.click()

        XCTAssertTrue(waitForLabel(of: dirtyState, equals: "clean", timeout: 5))
    }

    private func waitForLabel(of element: XCUIElement, equals value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}