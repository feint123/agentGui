import Testing
@testable import agentGui

struct ComposerAssistSelectionControllerTests {
    @Test func moveSelectionAdvancesWithinItemCount() {
        var controller = ComposerAssistSelectionController(itemCount: 3, selectedIndex: 0)

        controller.move(delta: 1)

        #expect(controller.selectedIndex == 1)
    }

    @Test func moveSelectionWrapsAroundWhenMovingPastEnd() {
        var controller = ComposerAssistSelectionController(itemCount: 2, selectedIndex: 1)

        controller.move(delta: 1)

        #expect(controller.selectedIndex == 0)
    }

    @Test func emptyControllerKeepsNilSelection() {
        var controller = ComposerAssistSelectionController(itemCount: 0, selectedIndex: 0)

        controller.move(delta: 1)

        #expect(controller.selectedIndex == nil)
    }
}