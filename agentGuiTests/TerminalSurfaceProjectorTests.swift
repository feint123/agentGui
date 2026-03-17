import Foundation
import Testing
@testable import agentGui

struct TerminalSurfaceProjectorTests {

    @Test func projectorBuildsMultiSelectSurfaceFromCreateVueScreen() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: TerminalInteractiveFixtures.createVueFeatureSelectionScreen
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init),
            activeBuffer: .alternate,
            cursor: .init(row: 4, column: 0),
            width: 80,
            height: 24
        )

        let surface = TerminalSurfaceProjector().project(snapshot)

        #expect(surface.selectionMode == .multiSelect)
        #expect(surface.visibleOptions.count == 4)
        #expect(surface.isAlternateScreen)
    }

    @Test func projectorBuildsSingleSelectSurfaceFromOverwritePrompt() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: [
                "┌  Vue.js - The Progressive JavaScript Framework",
                "",
                "◆  Target directory \"vue3-demo\" is not empty. Remove existing files and continue",
                "",
                "  ○ Yes / ● No"
            ],
            activeBuffer: .alternate,
            cursor: .init(row: 4, column: 0),
            width: 80,
            height: 24
        )

        let surface = TerminalSurfaceProjector().project(snapshot)

        #expect(surface.selectionMode == .singleSelect)
        #expect(surface.visibleOptions.map(\.label) == ["Yes", "No"])
        #expect(surface.visibleOptions.last?.isSelected == true)
        #expect(surface.plainTextFrame.contains("Target directory \"vue3-demo\" is not empty"))
    }

    @Test func projectorReturnsNoInteractiveSurfaceForPlainShellOutput() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: ["src", "package.json", "README.md"],
            activeBuffer: .primary,
            cursor: .init(row: 2, column: 0),
            width: 80,
            height: 24
        )

        let surface = TerminalSurfaceProjector().project(snapshot)

        #expect(surface.selectionMode == .none)
        #expect(surface.visibleOptions.isEmpty)
        #expect(surface.isAlternateScreen == false)
    }

    @Test func projectorRejectsMalformedSingleOptionGarbageAsInteractiveSurface() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: [
                "> npx",
                "> create-vue vue3-demo-1",
                "┌  Vue.js - The Progressive JavaScript Framework",
                "◆",
                "│?tp"
            ],
            activeBuffer: .primary,
            cursor: .init(row: 4, column: 0),
            width: 80,
            height: 24
        )

        let surface = TerminalSurfaceProjector().project(snapshot)

        #expect(surface.selectionMode == .unknown || surface.selectionMode == .none)
        #expect(surface.visibleOptions.count <= 1)
    }
}