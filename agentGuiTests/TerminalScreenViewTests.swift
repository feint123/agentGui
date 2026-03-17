import Foundation
import Testing
@testable import agentGui

@MainActor
struct TerminalScreenViewTests {

    @Test func terminalScreenViewFormatsSnapshotTextForDisplay() {
        let snapshot = TerminalScreenSnapshot(
            plainTextLines: ["◆  Select features", "│  ◻ JSX", "│  ◻ Router", ""],
            activeBuffer: .alternate,
            cursor: .init(row: 2, column: 4),
            width: 80,
            height: 24
        )

        let text = TerminalScreenView.displayText(for: snapshot)

        #expect(text.contains("◆  Select features"))
        #expect(text.contains("│  ◻ JSX"))
        #expect(text.contains("│  ◻ Router"))
    }
}