import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorTextViewIntegrationTests {
    @Test
    func userEditUpdatesBindingAndEmitsChangeSet() {
        let harness = CodeEditorTextViewHarness(text: "hello")

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")

        #expect(harness.boundText == "hello world")
        #expect(harness.document.text == "hello world")
        #expect(harness.lastChangeSet?.replacedRange == NSRange(location: 5, length: 0))
        #expect(harness.lastChangeSet?.insertedText == " world")
        #expect(harness.lastChangeSet?.origin == .userEdit)
    }

    @Test
    func selectionChangePublishesSelectionSnapshot() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

        harness.select(range: NSRange(location: 6, length: 4))

        #expect(harness.lastSelection?.text == "beta")
        #expect(harness.lastSelection?.lineRange == FileLineRange(startLine: 2, endLine: 2))
    }

    @Test
    func programmaticTextUpdateDoesNotEmitUserChange() {
        let harness = CodeEditorTextViewHarness(text: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "fresh", persistedText: "fresh")

        #expect(harness.boundText == "fresh")
        #expect(harness.document.text == "fresh")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChangeSet == nil)
    }

    @Test
    func textViewEnablesUndoAndSetsAccessibilityIdentifier() {
        let harness = CodeEditorTextViewHarness(text: "hello")

        #expect(harness.textView.allowsUndo)
        #expect(harness.textView.accessibilityIdentifier() == "codeEditor.textView")
    }
}