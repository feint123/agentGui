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
    func selectionSnapshotUsesUpdatedLineIndexAfterEdit() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta")

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "\n")
        harness.clearRecordedCallbacks()
        harness.select(range: NSRange(location: 6, length: 0))

        #expect(harness.document.lineRange(for: NSRange(location: 6, length: 0)) == FileLineRange(startLine: 2, endLine: 2))
        #expect(harness.lastSelection == nil)

        harness.select(range: NSRange(location: 7, length: 4))

        #expect(harness.lastSelection?.text == "beta")
        #expect(harness.lastSelection?.lineRange == FileLineRange(startLine: 3, endLine: 3))
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
    func staleHighlightResultDoesNotOverwriteNewerVersionAttributes() {
        let harness = CodeEditorTextViewHarness(
            text: "let a = 1",
            highlightExecutionDelayNanoseconds: 120_000_000
        )

        harness.replaceCharacters(in: NSRange(location: 4, length: 1), with: "b")
        harness.replaceCharacters(in: NSRange(location: 4, length: 1), with: "c")
        harness.waitForHighlightPass()

        #expect(harness.boundText == "let c = 1")
        #expect(harness.latestAppliedHighlightVersion == harness.document.version)
    }

    @Test
    func textViewEnablesUndoAndSetsAccessibilityIdentifier() {
        let harness = CodeEditorTextViewHarness(text: "hello")

        #expect(harness.textView.allowsUndo)
        #expect(harness.textView.accessibilityIdentifier() == "codeEditor.textView")
    }

    @Test
    func applyingHighlightPreservesTypingAttributes() {
        let harness = CodeEditorTextViewHarness(text: "let value = 1", language: "swift")
        let before = harness.textView.typingAttributes

        harness.forceApplyHighlightResult()

        #expect(NSDictionary(dictionary: harness.textView.typingAttributes).isEqual(to: before))
    }

    @Test
    func releasingHarnessWithPendingHighlightDoesNotCrash() {
        var harness: CodeEditorTextViewHarness? = CodeEditorTextViewHarness(
            text: "let value = 1",
            language: "swift",
            highlightExecutionDelayNanoseconds: 500_000_000
        )

        harness?.replaceCharacters(in: NSRange(location: 4, length: 5), with: "result")
        harness = nil

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(Bool(true))
    }
}