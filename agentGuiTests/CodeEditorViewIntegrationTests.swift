import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import agentGui

@MainActor
struct CodeEditorViewIntegrationTests {
    @Test
    func userEditForwardsTextChangeToHost() {
        let harness = CodeEditorViewHarness(initialText: "", persistedText: "")

        harness.replaceCharacters(in: NSRange(location: 0, length: 0), with: "hello")

        #expect(harness.lastForwardedText == "hello")
        #expect(harness.lastChange?.insertedText == "hello")
        #expect(harness.changeSetCount == 1)
    }

    @Test
    func reloadFromDiskReplacesEditorContentWithoutEchoingUserChange() {
        let harness = CodeEditorViewHarness(initialText: "old", persistedText: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "fresh", persistedText: "fresh")

        #expect(harness.visibleText == "fresh")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChange == nil)
    }

    @Test
    func persistedTextCleanSyncDoesNotEmitUserChange() {
        let harness = CodeEditorViewHarness(initialText: "draft", persistedText: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "draft", persistedText: "draft")

        #expect(harness.visibleText == "draft")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChange == nil)
    }

    @Test
    func focusRequestMakesTextViewFirstResponder() {
        let harness = CodeEditorViewHarness(initialText: "hello", persistedText: "hello")

        harness.requestFocus()

        #expect(harness.window.firstResponder === harness.textView)
    }

    @Test
    func userEditSchedulesHighlightWithoutReplacingPlainTextContent() {
        let harness = CodeEditorViewHarness(initialText: "let value = 1", persistedText: "let value = 1")

        harness.replaceCharacters(in: NSRange(location: 13, length: 0), with: "\nprint(value)")
        harness.waitForHighlightPass()

        #expect(harness.visibleText == "let value = 1\nprint(value)")
        #expect(harness.textView.selectedRange() == NSRange(location: 26, length: 0))
        #expect(harness.latestAppliedHighlightVersion == harness.documentVersion)
    }

    @Test
    func fileExtensionAliasStillProducesHighlightedAttributes() {
        let harness = CodeEditorViewHarness(
            initialText: "const value = 1",
            persistedText: "const value = 1",
            fileURL: URL(fileURLWithPath: "/tmp/sample.js")
        )

        harness.waitForHighlightPass()

        let keywordRange = (harness.visibleText as NSString).range(of: "const")
        let keywordColor = harness.textView.textStorage?.attribute(
            .foregroundColor,
            at: keywordRange.location,
            effectiveRange: nil
        ) as? NSColor

        #expect(keywordColor == NSColor.systemBlue)
    }
}

@MainActor
private final class CodeEditorViewHarness {
    private let highlighter = CodeSyntaxHighlightingService(engine: IdentityHighlightEngine())

    final class Recorder {
        var lastSelection: EditorSelectionSnapshot?
        var lastChange: EditorChangeSet?
        var lastForwardedText: String?
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var persistedText: String
        @Published var focusToken: UUID?

        init(text: String, persistedText: String) {
            self.text = text
            self.persistedText = persistedText
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    private let fileURL: URL
    let window: NSWindow
    private let hostingView: NSHostingView<HostView>

    init(initialText: String, persistedText: String, fileURL: URL = URL(fileURLWithPath: "/tmp/CodeEditorViewHarness.swift")) {
        let storage = Storage(text: initialText, persistedText: persistedText)
        self.storage = storage
        self.fileURL = fileURL
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            fileURL: fileURL,
            highlighter: highlighter,
            onSelectionChange: { snapshot in
                recorder.lastSelection = snapshot
            },
            onTextChange: { text, change in
                recorder.lastForwardedText = text
                recorder.lastChange = change
                recorder.changeSetCount += 1
            }
        )

        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)

        window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.displayIfNeeded()
        pumpRunLoop()
    }

    deinit {
        window.orderOut(nil)
        window.close()
    }

    var textView: CodeEditorPlatformTextView {
        guard let textView = findTextView(in: hostingView) else {
            fatalError("CodeEditorViewHarness could not find NSTextView")
        }
        return textView
    }

    var latestAppliedHighlightVersion: Int? {
        textView.latestAppliedHighlightVersion
    }

    var documentVersion: Int {
        recorder.lastChange?.version ?? 0
    }

    var visibleText: String {
        textView.string
    }

    var lastSelection: EditorSelectionSnapshot? {
        recorder.lastSelection
    }

    var lastChange: EditorChangeSet? {
        recorder.lastChange
    }

    var lastForwardedText: String? {
        recorder.lastForwardedText
    }

    var changeSetCount: Int {
        recorder.changeSetCount
    }

    func updateFromHost(text: String, persistedText: String) {
        storage.text = text
        storage.persistedText = persistedText
        pumpRunLoop()
    }

    func replaceCharacters(in range: NSRange, with replacement: String) {
        let textView = textView
        guard let storage = textView.textStorage else {
            fatalError("CodeEditorViewHarness missing text storage")
        }

        let selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        textView.setSelectedRange(range)
        _ = textView.shouldChangeText(in: range, replacementString: replacement)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()
        textView.setSelectedRange(selectedRange)
        textView.didChangeText()
        pumpRunLoop()
        pumpRunLoop()
    }

    func requestFocus() {
        storage.focusToken = UUID()
        pumpRunLoop()
    }

    func clearRecordedCallbacks() {
        recorder.lastSelection = nil
        recorder.lastChange = nil
        recorder.lastForwardedText = nil
        recorder.changeSetCount = 0
    }

    func waitForHighlightPass(timeoutSteps: Int = 300) {
        for _ in 0..<timeoutSteps {
            if latestAppliedHighlightVersion == documentVersion {
                return
            }
            pumpRunLoop()
        }
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func findTextView(in view: NSView) -> CodeEditorPlatformTextView? {
        if let textView = view as? CodeEditorPlatformTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }

        return nil
    }
}

private struct HostView: View {
    @ObservedObject var storage: CodeEditorViewHarness.Storage
    let fileURL: URL
    let highlighter: any CodeSyntaxHighlighting
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onTextChange: (String, EditorChangeSet) -> Void

    var body: some View {
        CodeEditorView(
            text: $storage.text,
            persistedText: storage.persistedText,
            fileURL: fileURL,
            focusRequest: storage.focusToken,
            onSelectionChange: onSelectionChange,
            onTextChange: onTextChange,
            highlighter: highlighter,
            highlightDebounceNanoseconds: 0
        )
        .frame(width: 480, height: 320)
    }
}

private final class IdentityHighlightEngine: CodeSyntaxHighlightingEngine {
    func highlight(
        code: String,
        language: String?,
        theme: CodeHighlightTheme
    ) -> NSAttributedString? {
        NSAttributedString(
            string: code,
            attributes: [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
            ]
        )
    }
}