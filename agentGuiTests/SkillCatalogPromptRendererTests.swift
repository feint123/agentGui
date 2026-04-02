import XCTest
@testable import agentGui

final class SkillCatalogPromptRendererTests: XCTestCase {

    // MARK: - Constants

    func test_defaultCharBudget_is8000() {
        XCTAssertEqual(SkillCatalogPromptRenderer.defaultCharBudget, 8_000)
    }

    func test_maxListingDescChars_is250() {
        XCTAssertEqual(SkillCatalogPromptRenderer.maxListingDescChars, 250)
    }

    func test_renderer_init_defaultBudget() {
        let renderer = SkillCatalogPromptRenderer()
        XCTAssertEqual(renderer.charBudget, SkillCatalogPromptRenderer.defaultCharBudget)
    }

    func test_renderer_init_customBudget() {
        let renderer = SkillCatalogPromptRenderer(charBudget: 500)
        XCTAssertEqual(renderer.charBudget, 500)
    }
}
