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
    var findQueryOverride: String? = nil
    var onFindStateChange: ((CodeEditorFindState) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0
    var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    var isBracketPairColorizationEnabled: Bool = false
    var documentSymbols: [LSPDocumentSymbol] = []
    var onSymbolPathChange: (([CodeEditorSymbolPathNode]) -> Void)? = nil
    var lspCoordinator: CodeEditorLSPCoordinator? = nil
    var isCompletionEnabled: Bool = false
    var isInlayHintsEnabled: Bool = false
    var isGhostTextEnabled: Bool = false
    var ghostTextClient: (any GhostTextClientProtocol)? = nil
    var ghostTextModelId: String = "claude-haiku-4-5"

    @State private var document: CodeEditorDocument
    @State private var findState = CodeEditorFindState.inactive
    @State private var visibleLineRange: ClosedRange<Int> = 1...1

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
        findQueryOverride: String? = nil,
        onFindStateChange: ((CodeEditorFindState) -> Void)? = nil,
        highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared,
        highlightDebounceNanoseconds: UInt64 = 75_000_000,
        highlightExecutionDelayNanoseconds: UInt64 = 0,
        gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:],
        isBracketPairColorizationEnabled: Bool = false,
        documentSymbols: [LSPDocumentSymbol] = [],
        onSymbolPathChange: (([CodeEditorSymbolPathNode]) -> Void)? = nil,
        lspCoordinator: CodeEditorLSPCoordinator? = nil,
        isCompletionEnabled: Bool = false,
        isInlayHintsEnabled: Bool = false,
        isGhostTextEnabled: Bool = false,
        ghostTextClient: (any GhostTextClientProtocol)? = nil,
        ghostTextModelId: String = "claude-haiku-4-5"
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
        self.findQueryOverride = findQueryOverride
        self.onFindStateChange = onFindStateChange
        self.highlighter = highlighter
        self.highlightDebounceNanoseconds = highlightDebounceNanoseconds
        self.highlightExecutionDelayNanoseconds = highlightExecutionDelayNanoseconds
        self.gitDiffByLine = gitDiffByLine
        self.isBracketPairColorizationEnabled = isBracketPairColorizationEnabled
        self.documentSymbols = documentSymbols
        self.onSymbolPathChange = onSymbolPathChange
        self.lspCoordinator = lspCoordinator
        self.isCompletionEnabled = isCompletionEnabled
        self.isInlayHintsEnabled = isInlayHintsEnabled
        self.isGhostTextEnabled = isGhostTextEnabled
        self.ghostTextClient = ghostTextClient
        self.ghostTextModelId = ghostTextModelId
        self._document = State(initialValue: CodeEditorDocument(text: text.wrappedValue, persistedText: persistedText))
    }

    var body: some View {
        VStack(spacing: 0) {
            if findState.isPresented {
                CodeEditorFindBar(
                    query: Binding(
                        get: { findState.query },
                        set: { updateFindQuery($0) }
                    ),
                    matchCount: totalFindMatchCount,
                    onPrevious: { handleFindIntent(.previousMatch) },
                    onNext: { handleFindIntent(.nextMatch) },
                    onClose: { handleFindIntent(.dismiss) }
                )
            }

            CodeEditorTextView(
                text: $text,
                document: $document,
                language: inferredLanguage,
                focusRequest: focusRequest,
                revealRequest: revealRequest,
                hoverPresentation: hoverPresentation,
                onSelectionChange: onSelectionChange,
                onVisibleLineRangeChange: { visibleLineRange = $0 },
                onSemanticIntent: onSemanticIntent,
                onFindIntent: handleFindIntent,
                decorations: decorationSnapshot,
                diagnosticsByLine: diagnosticsByLine,
                gitDiffByLine: gitDiffByLine,
                onChangeSet: { change in
                    onTextChange?(text, change)
                },
                highlighter: highlighter,
                highlightDebounceNanoseconds: highlightDebounceNanoseconds,
                highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds,
                isBracketPairColorizationEnabled: isBracketPairColorizationEnabled,
                indentationStatus: statusBarState.indentation,
                lspCoordinator: lspCoordinator,
                isCompletionEnabled: isCompletionEnabled,
                isInlayHintsEnabled: isInlayHintsEnabled,
                isGhostTextEnabled: isGhostTextEnabled,
                ghostTextClient: ghostTextClient,
                ghostTextModelId: ghostTextModelId
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
            onFindStateChange?(findState)
            onSymbolPathChange?(symbolBreadcrumbPath)
        }
        .onChange(of: document.selectedRange) { _, _ in
            onSymbolPathChange?(symbolBreadcrumbPath)
        }
        .onChange(of: documentSymbols) { _, _ in
            onSymbolPathChange?(symbolBreadcrumbPath)
        }
        .onChange(of: statusBarState.summaryText) { _, newSummary in
            onStatusBarSummaryChange?(newSummary)
        }
        .onChange(of: findState) { _, newState in
            onFindStateChange?(newState)
        }
        .onChange(of: findQueryOverride) { _, newQuery in
            guard let newQuery else {
                return
            }
            if findState.isPresented == false {
                findState.isPresented = true
            }
            updateFindQuery(newQuery)
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

    private var symbolBreadcrumbPath: [CodeEditorSymbolPathNode] {
        // document.location 返回 1-based line；转为 0-based 传给 symbolBreadcrumbNodes
        let line1 = document.location(ofUTF16Offset: document.selectedRange.location).line
        let line0 = max(0, line1 - 1)
        return CodeEditorViewModel.symbolBreadcrumbNodes(
            for: line0,
            in: documentSymbols,
            fileURL: fileURL
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

    private var totalFindMatchCount: Int {
        let snapshot = CodeEditorViewModel.findMatchSnapshot(
            document: document,
            findState: findState,
            visibleLineRange: 1...max(document.lineCount, 1)
        )
        return snapshot.spansByLine.values.reduce(0) { partialResult, spans in
            partialResult + spans.count
        }
    }

    private var decorationSnapshot: CodeEditorDecorationSnapshot {
        let lineRange = 1...max(document.lineCount, 1)
        let effectiveVisibleLineRange = clampLineRange(visibleLineRange, to: lineRange)
        let snapshots = [
            CodeEditorViewModel.findMatchSnapshot(
                document: document,
                findState: findState,
                visibleLineRange: effectiveVisibleLineRange
            ),
            CodeEditorViewModel.selectionMatchSnapshot(
                document: document,
                selectedRange: document.selectedRange,
                visibleLineRange: effectiveVisibleLineRange
            ),
            CodeEditorViewModel.diagnosticUnderlineSnapshot(
                diagnostics: diagnostics,
                document: document,
                visibleLineRange: effectiveVisibleLineRange
            )
        ]

        return mergeDecorationSnapshots(
            snapshots,
            version: document.version,
            lineRange: effectiveVisibleLineRange
        )
    }

    private func clampLineRange(
        _ lineRange: ClosedRange<Int>,
        to bounds: ClosedRange<Int>
    ) -> ClosedRange<Int> {
        let lowerBound = max(bounds.lowerBound, min(lineRange.lowerBound, bounds.upperBound))
        let upperBound = max(lowerBound, min(lineRange.upperBound, bounds.upperBound))
        return lowerBound...upperBound
    }

    private func mergeDecorationSnapshots(
        _ snapshots: [CodeEditorDecorationSnapshot],
        version: Int,
        lineRange: ClosedRange<Int>
    ) -> CodeEditorDecorationSnapshot {
        var spansByLine: [Int: [CodeEditorDecorationSpan]] = [:]

        for snapshot in snapshots {
            for (line, spans) in snapshot.spansByLine {
                spansByLine[line, default: []].append(contentsOf: spans)
            }
        }

        return CodeEditorDecorationSnapshot(
            version: version,
            lineRange: lineRange,
            spansByLine: spansByLine
        )
    }

    private func updateFindQuery(_ query: String) {
        findState.query = query
        let matchCount = totalFindMatchCount
        findState.selectedMatchIndex = matchCount > 0 && query.isEmpty == false ? 0 : nil
    }

    private func handleFindIntent(_ intent: CodeEditorFindIntent) {
        switch intent {
        case .present:
            findState.isPresented = true
            if findState.query.isEmpty == false, totalFindMatchCount > 0, findState.selectedMatchIndex == nil {
                findState.selectedMatchIndex = 0
            }

        case .dismiss:
            if findState.query.isEmpty {
                findState = .inactive
            } else {
                findState.query = ""
                findState.selectedMatchIndex = nil
            }

        case .nextMatch:
            advanceSelectedFindMatch(step: 1)

        case .previousMatch:
            advanceSelectedFindMatch(step: -1)
        }
    }

    private func advanceSelectedFindMatch(step: Int) {
        let matchCount = totalFindMatchCount
        guard matchCount > 0 else {
            findState.selectedMatchIndex = nil
            return
        }

        let currentIndex = findState.selectedMatchIndex ?? 0
        findState.selectedMatchIndex = (currentIndex + step + matchCount) % matchCount
    }
}