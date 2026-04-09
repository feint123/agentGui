import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorCompletionKeyboardTests {
    @Test
    func completionKeysAreConsumedWhenCompletionPanelIsVisible() {
        let harness = CodeEditorTextViewHarness(text: "alpha")
        let delegate = CompletionKeyDelegateSpy(isCompletionPanelVisible: true)
        harness.textView.completionDelegate = delegate
        harness.select(range: NSRange(location: 2, length: 0))

        harness.textView.keyDown(with: completionKeyEvent(keyCode: 48, characters: "\t"))
        harness.textView.keyDown(with: completionKeyEvent(keyCode: 36, characters: "\r"))
        harness.textView.keyDown(with: completionKeyEvent(keyCode: 125, characters: NSDownArrowFunctionKey.description))
        harness.textView.keyDown(with: completionKeyEvent(keyCode: 126, characters: NSUpArrowFunctionKey.description))

        #expect(delegate.acceptCount == 2)
        #expect(delegate.selectNextCount == 1)
        #expect(delegate.selectPrevCount == 1)
        #expect(harness.textView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(harness.changeSetCount == 0)
    }

    @Test
    func escapeDismissesCompletionWithoutCollapsingMultiCursorSelection() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")
        let delegate = CompletionKeyDelegateSpy(isCompletionPanelVisible: true)
        harness.textView.completionDelegate = delegate
        harness.textView.setSelectedRanges(
            [
                NSValue(range: NSRange(location: 1, length: 0)),
                NSValue(range: NSRange(location: 7, length: 0))
            ],
            affinity: .downstream,
            stillSelecting: false
        )

        #expect(harness.textView.selectedRanges.count == 2)

        harness.textView.keyDown(with: completionKeyEvent(keyCode: 53, characters: "\u{1b}"))
        harness.pumpRunLoop()

        #expect(delegate.dismissCount == 1)
        #expect(harness.textView.selectedRanges.count == 2)
    }
}

@MainActor
private final class CompletionKeyDelegateSpy: CompletionKeyDelegate {
    var isCompletionPanelVisible: Bool
    private(set) var acceptCount = 0
    private(set) var dismissCount = 0
    private(set) var selectNextCount = 0
    private(set) var selectPrevCount = 0

    init(isCompletionPanelVisible: Bool) {
        self.isCompletionPanelVisible = isCompletionPanelVisible
    }

    func acceptCompletion() {
        acceptCount += 1
    }

    func dismissCompletion() {
        dismissCount += 1
    }

    func selectNextCompletion() {
        selectNextCount += 1
    }

    func selectPrevCompletion() {
        selectPrevCount += 1
    }
}

private func completionKeyEvent(
    keyCode: UInt16,
    characters: String,
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}