import XCTest

class UITestBase: XCTestCase {
    let app = XCUIApplication()
    private let suppressOnboardingFlag = "-com.agentgui.test.suppressOnboarding"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func launchApp(arguments: [String] = []) {
        app.launchArguments = [
            "-com.agentgui.test.mode", "true",
            "-com.agentgui.test.preloadApiKey", "true",
            "-com.agentgui.test.preloadMessages", "true",
            "-com.agentgui.test.sessionId", "ui-test-session",
            "-com.agentgui.test.suppressOnboarding", "true"
        ] + arguments
        app.launch()
        dismissOnboardingIfPresent()
    }

    @MainActor
    func dismissOnboardingIfPresent() {
        if app.launchArguments.contains(suppressOnboardingFlag) {
            return
        }

        let skipButton = app.buttons["onboarding.skipButton"]
        guard skipButton.waitForExistence(timeout: 1) else { return }
        skipButton.click()

        let onboardingPanel = app.descendants(matching: .any)
            .matching(identifier: "onboarding.heroPanel")
            .firstMatch
        XCTAssertTrue(waitForDisappearance(of: onboardingPanel, timeout: 3))
    }

    @MainActor
    func openSettingsWindow() {
        app.activate()

        app.typeKey(",", modifierFlags: .command)

        let connectionField = app.descendants(matching: .any)
            .matching(identifier: "settings.connection.apiKeyField")
            .firstMatch

        if connectionField.waitForExistence(timeout: 2) {
            return
        }

        let appMenu = app.menuBars.menuBarItems["agentGui"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 2))
        appMenu.click()

        let settingsMenuItem = app.menuBars.menuItems["设置..."]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
        settingsMenuItem.click()
    }

    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}