import AppKit
import Combine
import SwiftUI
@testable import agentGui

@MainActor
final class CodeEditorTextViewHarness {
    final class Recorder {
        var lastChangeSet: EditorChangeSet?
        var lastSelection: EditorSelectionSnapshot?
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var document: CodeEditorDocument

        init(text: String, persistedText: String) {
            self.text = text
            self.document = CodeEditorDocument(text: text, persistedText: persistedText)
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    private let window: NSWindow
    private let hostingView: NSHostingView<HostView>
    private let language: String
    private let highlightExecutionDelayNanoseconds: UInt64
    private let highlighter: CodeSyntaxHighlightingService

    init(
        text: String,
        persistedText: String? = nil,
        language: String = "swift",
        highlightExecutionDelayNanoseconds: UInt64 = 0
    ) {
        let persistedText = persistedText ?? text
        let storage = Storage(text: text, persistedText: persistedText)
        self.storage = storage
        self.language = language
        self.highlightExecutionDelayNanoseconds = highlightExecutionDelayNanoseconds
        self.highlighter = CodeSyntaxHighlightingService(engine: IdentityHighlightEngine())
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            language: language,
            highlighter: highlighter,
            highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds,
            onSelectionChange: { snapshot in
                recorder.lastSelection = snapshot
            },
            onChangeSet: { change in
                recorder.lastChangeSet = change
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

    var boundText: String {
        storage.text
    }

    var lastChangeSet: EditorChangeSet? {
        recorder.lastChangeSet
    }

    var lastSelection: EditorSelectionSnapshot? {
        recorder.lastSelection
    }

    var changeSetCount: Int {
        recorder.changeSetCount
    }

    var document: CodeEditorDocument {
        storage.document
    }

    var textView: CodeEditorPlatformTextView {
        guard let textView = findTextView(in: hostingView) else {
            fatalError("CodeEditorTextViewHarness could not find NSTextView")
        }
        return textView
    }

    var latestAppliedHighlightVersion: Int? {
        textView.latestAppliedHighlightVersion
    }

    func forceApplyHighlightResult() {
        let textView = textView
        let attributedString = highlighter.highlightedString(
            code: textView.string,
            language: language,
            appearance: .light,
            fontSize: textView.font?.pointSize ?? NSFont.systemFontSize
        )

        CodeEditorHighlightApplicator.apply(
            CodeEditorHighlightResult(
                version: storage.document.version,
                lineRange: 1...max(storage.document.lineCount, 1),
                replacementRange: NSRange(location: 0, length: (textView.string as NSString).length),
                attributedString: attributedString
            ),
            to: textView,
            baseAttributes: [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textView.textColor ?? NSColor.labelColor
            ]
        )
        textView.latestAppliedHighlightVersion = storage.document.version
    }

    func replaceCharacters(in range: NSRange, with replacement: String) {
        let textView = textView
        guard let storage = textView.textStorage else {
            fatalError("CodeEditorTextViewHarness missing text storage")
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
    }

    func select(range: NSRange) {
        let textView = textView
        textView.setSelectedRange(range)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        waitUntil(timeoutSteps: 20) { recorder.lastSelection != nil }
    }

    func updateFromHost(text: String, persistedText: String? = nil) {
        storage.text = text
        storage.document = CodeEditorDocument(text: text, persistedText: persistedText ?? text, version: storage.document.version)
        pumpRunLoop()
    }

    func clearRecordedCallbacks() {
        recorder.lastChangeSet = nil
        recorder.lastSelection = nil
        recorder.changeSetCount = 0
    }

    func waitForHighlightPass(timeoutSteps: Int = 300) {
        waitUntil(timeoutSteps: timeoutSteps) {
            latestAppliedHighlightVersion == storage.document.version
        }
    }

    func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func waitUntil(timeoutSteps: Int, condition: () -> Bool) {
        for _ in 0..<timeoutSteps {
            if condition() {
                return
            }
            pumpRunLoop()
        }
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
    @ObservedObject var storage: CodeEditorTextViewHarness.Storage
    let language: String
    let highlighter: any CodeSyntaxHighlighting
    let highlightExecutionDelayNanoseconds: UInt64
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onChangeSet: (EditorChangeSet) -> Void

    var body: some View {
        CodeEditorTextView(
            text: $storage.text,
            document: $storage.document,
            language: language,
            onSelectionChange: onSelectionChange,
            onChangeSet: onChangeSet,
            highlighter: highlighter,
            highlightDebounceNanoseconds: 0,
            highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds
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