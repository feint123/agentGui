import AppKit
import SwiftUI

struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var language: String? = nil
    var focusRequest: UUID? = nil
    var revealRequest: CodeEditorRevealRequest? = nil
    var hoverPresentation: CodeEditorHoverPresentation? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onCursorLocationChange: ((CodeEditorTextLocation) -> Void)? = nil
    var onVisibleLineRangeChange: ((ClosedRange<Int>) -> Void)? = nil
    var onSemanticIntent: ((CodeEditorSemanticIntent) -> Void)? = nil
    var onFindIntent: ((CodeEditorFindIntent) -> Void)? = nil
    var decorations: CodeEditorDecorationSnapshot = .empty(version: 0, lineRange: 1...1)
    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] = [:]
    var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    var onGutterLaneHit: ((CodeEditorGutterHitResult) -> Void)? = nil
    var onChangeSet: ((EditorChangeSet) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0
    var isBracketPairColorizationEnabled: Bool = false
    var indentationStatus: CodeEditorIndentationStatus = CodeEditorIndentationStatus(kind: .unknown, width: 0)
    var lspCoordinator: CodeEditorLSPCoordinator? = nil
    var isCompletionEnabled: Bool = false
    var isInlayHintsEnabled: Bool = false
    var isSignatureHelpEnabled: Bool = false
    var isGhostTextEnabled: Bool = false
    var ghostTextClient: (any GhostTextClientProtocol)?
    var ghostTextModelId: String = "claude-haiku-4-5"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeEditorViewportContainerView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = CodeEditorPlatformTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.refreshDisplayedTextState()
        textView.currentDocumentVersion = document.version
        textView.setAccessibilityIdentifier("codeEditor.textView")
        textView.highlightedLineNumber = document.location(ofUTF16Offset: document.selectedRange.location).line
        textView.semanticIntentHandler = onSemanticIntent
        textView.findIntentHandler = onFindIntent
        textView.latestDecorationSnapshot = decorations
        textView.updateHoverPresentation(hoverPresentation)
        textView.compositionStateChangeHandler = { [weak coordinator = context.coordinator] textView in
            coordinator?.handleCompositionStateChange(in: textView)
        }

        scrollView.documentView = textView
        let containerView = CodeEditorViewportContainerView(scrollView: scrollView, textView: textView)
        context.coordinator.installGutter(for: containerView)
        context.coordinator.installSelectionObserver(for: textView)
        context.coordinator.installViewportObserver(for: scrollView, textView: textView)
        context.coordinator.schedulePostUpdateRefresh(for: textView, dirtyLineRange: nil)
        context.coordinator.syncRuntimeIntegrations(for: textView)
        return containerView
    }

    func updateNSView(_ containerView: CodeEditorViewportContainerView, context: Context) {
        let scrollView = containerView.scrollView
        let textView = containerView.textView
        context.coordinator.parent = self
        context.coordinator.installGutter(for: containerView)
        textView.semanticIntentHandler = onSemanticIntent
        textView.findIntentHandler = onFindIntent
        textView.currentDocumentVersion = document.version
        textView.latestDecorationSnapshot = decorations
        textView.updateHoverPresentation(hoverPresentation)

        var dirtyLineRange: ClosedRange<Int>?
        if !textView.hasMarkedText(), textView.string != text {
            let selectedRange = clampedRange(document.selectedRange, for: text)
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.string = text
            textView.refreshDisplayedTextState()
            textView.setSelectedRange(selectedRange)
            context.coordinator.isApplyingProgrammaticUpdate = false
            textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: selectedRange.location).line
            dirtyLineRange = context.coordinator.fullDocumentLineRange()
        }

        textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: textView.selectedRange().location).line
        context.coordinator.updateGutterState(for: textView)
        context.coordinator.updateAgentDiff(for: textView)
        context.coordinator.applyCachedHighlightPresentation(to: textView)
        context.coordinator.syncRuntimeIntegrations(for: textView)

        (textView as? CodeEditorPlatformTextView)?.indentGuideConfig =
            CodeEditorIndentGuideConfig(from: indentationStatus)

        context.coordinator.schedulePostUpdateRefresh(for: textView, dirtyLineRange: dirtyLineRange)

        if !isInlayHintsEnabled {
            textView.currentInlayHintSnapshot = .empty
        }

        if let focusRequest,
           context.coordinator.lastAppliedFocusRequest != focusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            context.coordinator.applyFocus(to: textView)
        }

        if let revealRequest,
           context.coordinator.lastAppliedRevealRequestID != revealRequest.id {
            context.coordinator.lastAppliedRevealRequestID = revealRequest.id
            context.coordinator.applyRevealRequest(revealRequest, to: textView)
        }
    }

    private func clampedRange(_ range: NSRange, for text: String) -> NSRange {
        let length = text.utf16.count
        let location = max(0, min(range.location, length))
        let safeLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }
}
