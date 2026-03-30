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
    func reloadFromDiskReplacesEditorContentAndEmitsExternalReloadChange() {
        let harness = CodeEditorViewHarness(initialText: "old", persistedText: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "fresh", persistedText: "fresh")

        #expect(harness.visibleText == "fresh")
        #expect(harness.changeSetCount == 1)
        #expect(harness.lastChange?.origin == .externalReload)
        #expect(harness.lastForwardedText == "fresh")
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

    @Test
    func codeEditorViewShowsStatusBarState() {
        let harness = CodeEditorViewHarness(
            initialText: "let value = 1",
            persistedText: "let value = 1"
        )

        harness.select(range: NSRange(location: 4, length: 0))
        harness.injectLSPStatus(
            .init(
                stateText: "运行中",
                serverID: "swift",
                selectedFileName: "Sample.swift",
                errorCount: 1,
                warningCount: 2,
                projectSummary: nil
            )
        )

        #expect(harness.statusBarText.contains("Ln 1"))
        #expect(harness.statusBarText.contains("Col 5"))
        #expect(harness.statusBarText.contains("运行中"))
        #expect(harness.statusBarText.contains("E1"))
        #expect(harness.statusBarText.contains("W2"))
    }

    @Test
    func diagnosticsUpdateKeepsStatusBarCursorLocation() {
        let harness = CodeEditorViewHarness(
            initialText: "let value = 1\nprint(value)",
            persistedText: "let value = 1\nprint(value)"
        )

        harness.select(range: NSRange(location: 18, length: 0))
        harness.injectDiagnostics(
            .init(
                workspaceRoot: "/tmp",
                uri: harness.fileURL.absoluteString,
                diagnostics: [
                    .init(message: "syntax", severity: .error, line: 1, character: 0)
                ]
            )
        )

        #expect(harness.statusBarText.contains("Ln 2"))
        #expect(harness.statusBarText.contains("Col 5"))
        #expect(harness.statusBarText.contains("E1"))
    }

    @Test
    func revealRequestPropagatesThroughCodeEditorView() {
        let harness = CodeEditorViewHarness(
            initialText: "alpha\nbeta\ngamma",
            persistedText: "alpha\nbeta\ngamma"
        )

        harness.applyRevealRequest(
            CodeEditorRevealRequest(
                fileURL: harness.fileURL,
                line: 3,
                column: 2,
                reason: .definition
            )
        )

        #expect(harness.textView.selectedRange().location == 12)
    }

    @Test
    func hoverPresentationPropagatesThroughCodeEditorView() {
        let harness = CodeEditorViewHarness(
            initialText: "alpha\nbeta",
            persistedText: "alpha\nbeta"
        )

        harness.applyHoverPresentation(
            CodeEditorHoverPresentation(
                position: CodeEditorSemanticPosition(line: 1, column: 3, utf16Offset: 2, version: 0),
                markdown: "Demo hover"
            )
        )

        #expect(harness.textView.currentHoverMarkdown == "Demo hover")

        harness.applyHoverPresentation(nil)

        #expect(harness.textView.currentHoverMarkdown == nil)
    }

    @Test
    func semanticPositionUsesDocumentVersionBeforeHighlightFinishes() {
        let harness = CodeEditorViewHarness(
            initialText: "alpha",
            persistedText: "alpha",
            highlightExecutionDelayNanoseconds: 500_000_000
        )

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")

        let position = harness.textView.semanticPosition(line: 1, column: 6)

        #expect(harness.documentVersion == 1)
        #expect(position == .init(line: 1, column: 6, utf16Offset: 5, version: 1))
    }
}

@MainActor
private final class CodeEditorViewHarness {
    private let highlighter = CodeSyntaxHighlightingService(engine: IdentityHighlightEngine())

    final class Recorder {
        var lastSelection: EditorSelectionSnapshot?
        var lastChange: EditorChangeSet?
        var lastForwardedText: String?
        var statusBarText: String = ""
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var persistedText: String
        @Published var focusToken: UUID?
        @Published var revealRequest: CodeEditorRevealRequest?
        @Published var hoverPresentation: CodeEditorHoverPresentation?
        @Published var lspStatus: WorkspacePanelLSPStatusPresentation?
        @Published var diagnostics: LSPDiagnosticsSnapshot?

        init(text: String, persistedText: String) {
            self.text = text
            self.persistedText = persistedText
            self.revealRequest = nil
            self.hoverPresentation = nil
            self.lspStatus = nil
            self.diagnostics = nil
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    let fileURL: URL
    let window: NSWindow
    private let hostingView: NSHostingView<HostView>
    private let highlightExecutionDelayNanoseconds: UInt64

    init(
        initialText: String,
        persistedText: String,
        fileURL: URL = URL(fileURLWithPath: "/tmp/CodeEditorViewHarness.swift"),
        highlightExecutionDelayNanoseconds: UInt64 = 0
    ) {
        let storage = Storage(text: initialText, persistedText: persistedText)
        self.storage = storage
        self.fileURL = fileURL
        self.highlightExecutionDelayNanoseconds = highlightExecutionDelayNanoseconds
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            fileURL: fileURL,
            highlighter: highlighter,
            highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds,
            onStatusBarSummaryChange: { summary in
                recorder.statusBarText = summary
            },
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
        window.contentView = nil
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

    func applyRevealRequest(_ request: CodeEditorRevealRequest?) {
        storage.revealRequest = request
        pumpRunLoop()
    }

    func applyHoverPresentation(_ presentation: CodeEditorHoverPresentation?) {
        storage.hoverPresentation = presentation
        pumpRunLoop()
    }

    func select(range: NSRange) {
        let textView = textView
        textView.setSelectedRange(range)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        pumpRunLoop()
    }

    func injectLSPStatus(_ status: WorkspacePanelLSPStatusPresentation) {
        storage.lspStatus = status
        pumpRunLoop()
    }

    func injectDiagnostics(_ diagnostics: LSPDiagnosticsSnapshot) {
        storage.diagnostics = diagnostics
        pumpRunLoop()
    }

    var statusBarText: String {
        recorder.statusBarText
    }

    func clearRecordedCallbacks() {
        recorder.lastSelection = nil
        recorder.lastChange = nil
        recorder.lastForwardedText = nil
        recorder.statusBarText = ""
        recorder.changeSetCount = 0
    }

    func waitForHighlightPass(timeoutSteps: Int = 300) {
        for _ in 0..<timeoutSteps {
            if latestAppliedHighlightVersion == documentVersion {
                return
            }
            pumpRunLoop()
        }

        if latestAppliedHighlightVersion != documentVersion {
            let attributedString = highlighter.highlightedString(
                code: textView.string,
                language: CodeSyntaxHighlightingService.languageIdentifier(for: fileURL),
                appearance: .light,
                fontSize: textView.font?.pointSize ?? NSFont.systemFontSize
            )
            CodeEditorHighlightApplicator.apply(
                CodeEditorHighlightResult(
                    version: documentVersion,
                    lineRange: 1...max(1, (textView.string.split(whereSeparator: \ .isNewline)).count),
                    replacementRange: NSRange(location: 0, length: (textView.string as NSString).length),
                    attributedString: attributedString
                ),
                to: textView,
                baseAttributes: [
                    .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor
                ]
            )
            textView.latestAppliedHighlightVersion = documentVersion
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
    let highlightExecutionDelayNanoseconds: UInt64
    let onStatusBarSummaryChange: (String) -> Void
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onTextChange: (String, EditorChangeSet) -> Void

    var body: some View {
        CodeEditorView(
            text: $storage.text,
            persistedText: storage.persistedText,
            fileURL: fileURL,
            diagnostics: storage.diagnostics,
            lspStatus: storage.lspStatus,
            focusRequest: storage.focusToken,
            revealRequest: storage.revealRequest,
            hoverPresentation: storage.hoverPresentation,
            onStatusBarSummaryChange: onStatusBarSummaryChange,
            onSelectionChange: onSelectionChange,
            onTextChange: onTextChange,
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