import Foundation
import SwiftUI

struct CodeEditorView: View {
    @Binding var text: String
    let persistedText: String
    let fileURL: URL
    var diagnostics: LSPDiagnosticsSnapshot? = nil
    var lspStatus: WorkspacePanelLSPStatusPresentation? = nil
    var focusRequest: UUID? = nil
    var revealRequest: CodeEditorRevealRequest? = nil
    var hoverPresentation: CodeEditorHoverPresentation? = nil
    var onStatusBarSummaryChange: ((String) -> Void)? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onSemanticIntent: ((CodeEditorSemanticIntent) -> Void)? = nil
    var onTextChange: ((String, EditorChangeSet) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0

    @State private var document: CodeEditorDocument

    init(
        text: Binding<String>,
        persistedText: String,
        fileURL: URL,
        diagnostics: LSPDiagnosticsSnapshot? = nil,
        lspStatus: WorkspacePanelLSPStatusPresentation? = nil,
        focusRequest: UUID? = nil,
        revealRequest: CodeEditorRevealRequest? = nil,
        hoverPresentation: CodeEditorHoverPresentation? = nil,
        onStatusBarSummaryChange: ((String) -> Void)? = nil,
        onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil,
        onSemanticIntent: ((CodeEditorSemanticIntent) -> Void)? = nil,
        onTextChange: ((String, EditorChangeSet) -> Void)? = nil,
        highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared,
        highlightDebounceNanoseconds: UInt64 = 75_000_000,
        highlightExecutionDelayNanoseconds: UInt64 = 0
    ) {
        self._text = text
        self.persistedText = persistedText
        self.fileURL = fileURL
        self.diagnostics = diagnostics
        self.lspStatus = lspStatus
        self.focusRequest = focusRequest
        self.revealRequest = revealRequest
        self.hoverPresentation = hoverPresentation
        self.onStatusBarSummaryChange = onStatusBarSummaryChange
        self.onSelectionChange = onSelectionChange
        self.onSemanticIntent = onSemanticIntent
        self.onTextChange = onTextChange
        self.highlighter = highlighter
        self.highlightDebounceNanoseconds = highlightDebounceNanoseconds
        self.highlightExecutionDelayNanoseconds = highlightExecutionDelayNanoseconds
        self._document = State(initialValue: CodeEditorDocument(text: text.wrappedValue, persistedText: persistedText))
    }

    var body: some View {
        VStack(spacing: 0) {
            CodeEditorTextView(
                text: $text,
                document: $document,
                language: inferredLanguage,
                focusRequest: focusRequest,
                revealRequest: revealRequest,
                hoverPresentation: hoverPresentation,
                onSelectionChange: onSelectionChange,
                onSemanticIntent: onSemanticIntent,
                diagnosticsByLine: diagnosticsByLine,
                onChangeSet: { change in
                    onTextChange?(text, change)
                },
                highlighter: highlighter,
                highlightDebounceNanoseconds: highlightDebounceNanoseconds,
                highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds
            )
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            CodeEditorStatusBar(state: statusBarState)
        }
        .onChange(of: text) { _, newText in
            syncHostText(newText)
        }
        .onChange(of: persistedText) { _, newPersistedText in
            syncPersistedText(newPersistedText)
        }
        .onAppear {
            onStatusBarSummaryChange?(statusBarState.summaryText)
        }
        .onChange(of: statusBarState.summaryText) { _, newSummary in
            onStatusBarSummaryChange?(newSummary)
        }
    }

    private var statusBarState: CodeEditorStatusBarState {
        CodeEditorViewModel.makeStatusBarState(
            document: document,
            selectedRange: document.selectedRange,
            fileURL: fileURL,
            lspStatus: lspStatus,
            diagnostics: diagnostics
        )
    }

    private var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] {
        diagnostics.map(CodeEditorViewModel.diagnosticsByLine) ?? [:]
    }

    private func syncHostText(_ hostText: String) {
        guard hostText != document.text else { return }
        let selectedRange = clampedSelection(for: hostText)
        let change = document.replaceFromDisk(
            text: hostText,
            persistedText: persistedText,
            selectedRange: selectedRange
        )
        onTextChange?(hostText, change)
    }

    private func syncPersistedText(_ hostPersistedText: String) {
        guard hostPersistedText != document.persistedText else { return }
        document.syncPersistedText(hostPersistedText)
    }

    private func clampedSelection(for text: String) -> NSRange {
        let length = text.utf16.count
        let location = max(0, min(document.selectedRange.location, length))
        let safeLength = max(0, min(document.selectedRange.length, length - location))
        return NSRange(location: location, length: safeLength)
    }

    private var inferredLanguage: String? {
        CodeSyntaxHighlightingService.languageIdentifier(for: fileURL)
    }
}