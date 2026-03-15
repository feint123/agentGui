import AppKit
import Testing
@testable import agentGui

@MainActor
struct WorkspaceInlineEditorTests {

    @Test func choosesCommitWhenEditingEndsWithReturn() {
        let action = InlineEditorTextField.endEditingAction(for: NSReturnTextMovement)

        #expect(action == .commit)
    }

    @Test func choosesCancelWhenEditingEndsWithoutReturn() {
        let action = InlineEditorTextField.endEditingAction(for: NSTabTextMovement)

        #expect(action == .cancel)
    }
}