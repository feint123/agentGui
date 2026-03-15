import XCTest

final class SessionManagementUITests: UITestBase {

    @MainActor
    func testCreateSessionShowsEmptyChatState() throws {
        launchApp()

        XCTAssertTrue(app.popUpButtons["chat.sessionPicker"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["chat.newSessionButton"].waitForExistence(timeout: 2))

        app.buttons["chat.newSessionButton"].click()

        XCTAssertTrue(app.staticTexts["开始对话"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testUnconfiguredLaunchShowsDedicatedOnboardingWindow() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadApiKey", "false",
            "-com.agentgui.test.preloadMessages", "false"
        ])

        XCTAssertTrue(app.staticTexts["onboarding.step.welcome.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.nextButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingCanAdvanceToConnectionStep() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadApiKey", "false",
            "-com.agentgui.test.preloadMessages", "false"
        ])

        let nextButton = app.buttons["onboarding.nextButton"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 5))
        nextButton.click()

        XCTAssertTrue(app.staticTexts["onboarding.step.connection.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.validateButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingShowsModernStepRailLayout() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadApiKey", "false",
            "-com.agentgui.test.preloadMessages", "false"
        ])

        XCTAssertTrue(app.otherElements["onboarding.stepRail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["onboarding.heroPanel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["onboarding.backgroundLayer"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOnboardingShowsWelcomeWindowChromeRegions() throws {
        launchApp(arguments: [
            "-com.agentgui.test.preloadApiKey", "false",
            "-com.agentgui.test.preloadMessages", "false"
        ])

        XCTAssertTrue(app.otherElements["onboarding.windowChromeRegion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["onboarding.heroDragRegion"].waitForExistence(timeout: 5))
    }
}