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

    @Test
    func commandFFromTextViewPresentsFindBarWithoutEditingDocument() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta alpha", persistedText: "alpha beta alpha")

        harness.sendFindShortcut()

        #expect(harness.isFindBarPresented)
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChange == nil)
    }

    @Test
    func escapeClosesFindBarWhenQueryIsEmpty() {
        let harness = CodeEditorViewHarness(initialText: "alpha", persistedText: "alpha")

        harness.presentFindBar()
        harness.setFindQuery("")
        harness.sendEscape()

        #expect(harness.isFindBarPresented == false)
    }

    @Test
    func enterAndShiftEnterMoveSelectedFindMatch() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta alpha gamma alpha", persistedText: "alpha beta alpha gamma alpha")

        harness.presentFindBar()
        harness.setFindQuery("alpha")

        #expect(harness.selectedFindMatchIndex == 0)

        harness.sendFindNext()
        #expect(harness.selectedFindMatchIndex == 1)

        harness.sendFindPrevious()
        #expect(harness.selectedFindMatchIndex == 0)
    }

    @Test
    func findQueryAppliesVisibleMatchBackgrounds() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta alpha", persistedText: "alpha beta alpha")

        harness.waitForHighlightPass()
        harness.presentFindBar()
        harness.setFindQuery("alpha")
        harness.waitForDecorationUpdate {
            harness.backgroundColor(at: 0) != nil && harness.backgroundColor(at: 11) != nil
        }

        #expect(harness.backgroundColor(at: 0) == NSColor.systemOrange.withAlphaComponent(0.35))
        #expect(harness.backgroundColor(at: 11) == NSColor.systemYellow.withAlphaComponent(0.28))
    }

    @Test
    func selectionAppliesSelectionMatchBackgrounds() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta alpha", persistedText: "alpha beta alpha")

        harness.waitForHighlightPass()
        harness.select(range: NSRange(location: 0, length: 5))
        harness.waitForDecorationUpdate {
            harness.backgroundColor(at: 11) != nil
        }

        #expect(harness.backgroundColor(at: 11) == NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18))
    }

    @Test
    func diagnosticsApplyUnderlineAttributesWithinVisibleRange() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta", persistedText: "alpha beta")

        harness.waitForHighlightPass()
        harness.injectDiagnostics(
            .init(
                workspaceRoot: "/tmp",
                uri: harness.fileURL.absoluteString,
                diagnostics: [
                    .init(
                        message: "problem",
                        severity: .warning,
                        line: 0,
                        character: 6,
                        endLine: 0,
                        endCharacter: 10
                    )
                ]
            )
        )
        harness.waitForDecorationUpdate {
            harness.underlineStyle(at: 6) != nil && harness.underlineColor(at: 6) != nil
        }

        #expect(harness.underlineStyle(at: 6) == NSUnderlineStyle.single.rawValue)
        #expect(harness.underlineColor(at: 6) == NSColor.systemOrange)
    }
    
    @Test
    func compositionStateSuppressesDecorationApplication() {
        let harness = CodeEditorViewHarness(initialText: "alpha beta alpha", persistedText: "alpha beta alpha")

        harness.waitForHighlightPass()
        harness.clearReappliedLines()
        harness.beginMarkedTextComposition("拼")
        harness.presentFindBar()
        harness.setFindQuery("alpha")
        harness.injectDiagnostics(
            .init(
                workspaceRoot: "/tmp",
                uri: harness.fileURL.absoluteString,
                diagnostics: [
                    .init(
                        message: "problem",
                        severity: .warning,
                        line: 0,
                        character: 6,
                        endLine: 0,
                        endCharacter: 10
                    )
                ]
            )
        )
        harness.waitForDecorationUpdate { true }

        #expect(harness.lastReappliedLines.isEmpty)
        #expect(harness.backgroundColor(at: 0) == nil)
        #expect(harness.underlineStyle(at: 6) == nil)
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
        var lastFindState = CodeEditorFindState(
            isPresented: false,
            query: "",
            caseSensitive: false,
            selectedMatchIndex: nil
        )
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var persistedText: String
        @Published var focusToken: UUID?
        @Published var revealRequest: CodeEditorRevealRequest?
        @Published var hoverPresentation: CodeEditorHoverPresentation?
        @Published var lspStatus: WorkspacePanelLSPStatusPresentation?
        @Published var diagnostics: LSPDiagnosticsSnapshot?
        @Published var findQueryOverride: String?

        init(text: String, persistedText: String) {
            self.text = text
            self.persistedText = persistedText
            self.revealRequest = nil
            self.hoverPresentation = nil
            self.lspStatus = nil
            self.diagnostics = nil
            self.findQueryOverride = nil
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
            },
            onFindStateChange: { state in
                recorder.lastFindState = state
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

    var isFindBarPresented: Bool {
        recorder.lastFindState.isPresented
    }

    var selectedFindMatchIndex: Int? {
        recorder.lastFindState.selectedMatchIndex
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

    func beginMarkedTextComposition(_ markedText: String) {
        let replacementRange = NSRange(location: textView.string.utf16.count, length: 0)
        textView.setMarkedText(
            markedText,
            selectedRange: NSRange(location: markedText.utf16.count, length: 0),
            replacementRange: replacementRange
        )
        pumpRunLoop()
    }

    func presentFindBar() {
        sendFindShortcut()
    }

    func setFindQuery(_ query: String) {
        storage.findQueryOverride = query
        pumpRunLoop()
    }

    func sendFindShortcut() {
        _ = textView.performKeyEquivalent(with: Self.keyEvent(characters: "f", modifierFlags: [.command]))
        pumpRunLoop()
    }

    func sendEscape() {
        _ = textView.performKeyEquivalent(with: Self.keyEvent(keyCode: 53, characters: "\u{1b}"))
        pumpRunLoop()
    }

    func sendFindNext() {
        _ = textView.performKeyEquivalent(with: Self.keyEvent(keyCode: 36, characters: "\r"))
        pumpRunLoop()
    }

    func sendFindPrevious() {
        _ = textView.performKeyEquivalent(with: Self.keyEvent(keyCode: 36, characters: "\r", modifierFlags: [.shift]))
        pumpRunLoop()
    }

    var statusBarText: String {
        recorder.statusBarText
    }

    var lastReappliedLines: [Int] {
        textView.lastReappliedLines
    }

    func backgroundColor(at location: Int) -> NSColor? {
        textView.textStorage?.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func underlineStyle(at location: Int) -> Int? {
        textView.textStorage?.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
    }

    func underlineColor(at location: Int) -> NSColor? {
        textView.textStorage?.attribute(.underlineColor, at: location, effectiveRange: nil) as? NSColor
    }

    func clearReappliedLines() {
        textView.lastReappliedLines = []
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
            let lineCount = max((textView.string.split(whereSeparator: \ .isNewline)).count, 1)
            let document = CodeEditorDocument(text: textView.string, persistedText: textView.string, version: documentVersion)
            let lineFragments = (1...lineCount).map { line in
                let range = document.utf16LineRange(forLine: line)
                return CodeEditorStyledLineFragment(
                    line: line,
                    utf16Range: range,
                    attributedString: attributedString.attributedSubstring(from: range),
                    fingerprint: line * 1000 + range.length
                )
            }
            let result = CodeEditorHighlightResult(
                version: documentVersion,
                lineRange: 1...lineCount,
                lineFragments: lineFragments
            )
            _ = CodeEditorHighlightApplicator.apply(
                result,
                decorations: .empty(version: documentVersion, lineRange: 1...lineCount),
                to: textView,
                baseAttributes: [
                    .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    .foregroundColor: textView.textColor ?? NSColor.labelColor
                ]
            )
            textView.latestHighlightResult = result
            textView.latestAppliedHighlightVersion = documentVersion
        }
    }

    func waitForDecorationUpdate(
        timeoutSteps: Int = 60,
        condition: () -> Bool
    ) {
        for _ in 0..<timeoutSteps {
            if condition() {
                return
            }
            pumpRunLoop()
        }
    }

    private func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private static func keyEvent(
        keyCode: UInt16 = 3,
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
    let onFindStateChange: (CodeEditorFindState) -> Void

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
            findQueryOverride: storage.findQueryOverride,
            onFindStateChange: onFindStateChange,
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