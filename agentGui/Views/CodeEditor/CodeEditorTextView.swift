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
    var onChangeSet: ((EditorChangeSet) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0
    var isBracketPairColorizationEnabled: Bool = false

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
        context.coordinator.applyCachedHighlightPresentation(to: textView)

        context.coordinator.schedulePostUpdateRefresh(for: textView, dirtyLineRange: dirtyLineRange)

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

extension CodeEditorTextView {
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorTextView
        var isApplyingProgrammaticUpdate = false
        var lastAppliedFocusRequest: UUID?
        var lastAppliedRevealRequestID: UUID?
        private var selectionObserver: NSObjectProtocol?
        private var viewportObserver: NSObjectProtocol?
        private var pendingEdit: PendingEdit?
        private let highlightScheduler = CodeEditorHighlightScheduler()
        private let highlightPipeline = CodeEditorHighlightPipeline()
        private var lastScheduledHighlightVersion: Int?
        private var lastScheduledVisibleLineRange: ClosedRange<Int>?
        private var lastPublishedVisibleLineRange: ClosedRange<Int>?
        private var pendingPostUpdateRefreshID: UUID?

        init(_ parent: CodeEditorTextView) {
            self.parent = parent
        }

        deinit {
            let highlightScheduler = self.highlightScheduler
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            Task {
                await highlightScheduler.cancel()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                return true
            }

            (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

            pendingEdit = PendingEdit(
                replacedRange: affectedCharRange,
                insertedText: replacementString ?? ""
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeEditorPlatformTextView else { return }
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                return
            }

            textView.refreshDisplayedTextState()

            if textView.hasMarkedText() {
                publishSelection(for: textView)
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                cancelHighlight()
                return
            }

            commitDisplayedText(from: textView, preferPendingEdit: true)
        }

        func handleCompositionStateChange(in textView: CodeEditorPlatformTextView) {
            guard !isApplyingProgrammaticUpdate else {
                return
            }

            publishSelection(for: textView)
            publishVisibleLineRange(for: textView)
            updateGutterState(for: textView)

            if textView.hasMarkedText() {
                // IME 期间清除括号高亮，避免视觉混乱
                textView.applyBracketMatchHighlight(nil)
                cancelHighlight()
                return
            }

            textView.emitSemanticIntent(.cancelHover)

            guard textView.string != parent.document.text else {
                scheduleHighlight(for: textView, dirtyLineRange: nil)
                return
            }

            commitDisplayedText(from: textView, preferPendingEdit: false)
        }

        func installSelectionObserver(for textView: NSTextView) {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }

            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: nil
            ) { [weak self, weak textView] _ in
                guard let self, let textView, !self.isApplyingProgrammaticUpdate else { return }
                (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, !self.isApplyingProgrammaticUpdate else { return }
                    self.publishSelection(for: textView)
                }
            }
        }

        func installGutter(for containerView: CodeEditorViewportContainerView) {
            containerView.gutterView.onRequiredWidthChange = { [weak containerView] in
                containerView?.needsLayout = true
            }
        }

        func installViewportObserver(for scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }

            scrollView.contentView.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                textView.emitSemanticIntent(.cancelHover)
                self.scheduleHighlight(for: textView, dirtyLineRange: nil)
            }
        }

        func publishSelection(for textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let cursorLocation: CodeEditorTextLocation
            if let textView = textView as? CodeEditorPlatformTextView {
                cursorLocation = textView.displayedLocation(ofUTF16Offset: selectedRange.location)
            } else {
                cursorLocation = parent.document.location(ofUTF16Offset: selectedRange.location)
            }
            let snapshot = selectionSnapshot(for: textView, text: textView.string, range: selectedRange)
            parent.onSelectionChange?(snapshot)
            parent.onCursorLocationChange?(cursorLocation)
            (textView as? CodeEditorPlatformTextView)?.highlightedLineNumber = cursorLocation.line
            updateGutterState(for: textView)
            parent.document.markSelection(selectedRange)

            // 括号高亮
            if let platformTextView = textView as? CodeEditorPlatformTextView,
               !platformTextView.hasMarkedText() {
                let cursorOffset = textView.selectedRange().location
                let matchResult = CodeEditorBracketScanner.findMatch(
                    in: platformTextView.string,
                    cursorOffset: cursorOffset
                )
                platformTextView.applyBracketMatchHighlight(matchResult)
            }
        }

        func publishVisibleLineRange(for textView: NSTextView) {
            guard let visibleLineRange = visibleLineRange(for: textView) else {
                return
            }

            guard visibleLineRange != lastPublishedVisibleLineRange else {
                return
            }

            lastPublishedVisibleLineRange = visibleLineRange
            parent.onVisibleLineRangeChange?(visibleLineRange)
            updateGutterState(for: textView)
        }

        func updateGutterState(for textView: NSTextView) {
            guard let textView = textView as? CodeEditorPlatformTextView,
                  let gutterView = gutterView(for: textView),
                  let scrollView = textView.enclosingScrollView else {
                return
            }

            let visibleRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            let lineMetrics = textView.visibleLineMetrics(in: scrollView.contentView.bounds).map { metric in
                let convertedRect = gutterView.convert(metric.rect, from: textView)
                return CodeEditorVisibleLineMetric(
                    line: metric.line,
                    rect: NSRect(x: 0, y: convertedRect.minY, width: gutterView.requiredWidth, height: convertedRect.height).integral,
                    baselineY: gutterView.convert(NSPoint(x: 0, y: metric.baselineY), from: textView).y
                )
            }
            let snapshot = CodeEditorGutterLineMetricsSnapshot(
                lineCount: textView.displayedLineCount,
                visibleLineRange: visibleRange,
                currentLine: textView.highlightedLineNumber,
                lineMetrics: lineMetrics,
                diagnosticsByLine: parent.diagnosticsByLine,
                gitDiffByLine: parent.gitDiffByLine
            )
            gutterView.updateLayoutState(snapshot)
        }

        private func gutterView(for textView: CodeEditorPlatformTextView) -> CodeEditorGutterView? {
            var currentView = textView.enclosingScrollView?.superview
            while let view = currentView {
                if let containerView = view as? CodeEditorViewportContainerView {
                    return containerView.gutterView
                }
                currentView = view.superview
            }
            return nil
        }

        func applyFocus(to textView: NSTextView) {
            if let window = textView.window {
                window.makeFirstResponder(textView)
                return
            }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyFocus(to: textView)
            }
        }

        func applyRevealRequest(_ request: CodeEditorRevealRequest, to textView: CodeEditorPlatformTextView) {
            isApplyingProgrammaticUpdate = true
            textView.applyRevealRequest(request)
            isApplyingProgrammaticUpdate = false
            textView.updateHoverPresentation(nil)
            updateGutterState(for: textView)
        }

        func schedulePostUpdateRefresh(
            for textView: CodeEditorPlatformTextView,
            dirtyLineRange: ClosedRange<Int>?
        ) {
            let refreshID = UUID()
            pendingPostUpdateRefreshID = refreshID
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.pendingPostUpdateRefreshID == refreshID else { return }
                self.pendingPostUpdateRefreshID = nil
                self.publishSelection(for: textView)
                self.scheduleHighlight(for: textView, dirtyLineRange: dirtyLineRange)
            }
        }

        func scheduleHighlight(
            for textView: CodeEditorPlatformTextView,
            dirtyLineRange: ClosedRange<Int>?
        ) {
            if textView.hasMarkedText() {
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                cancelHighlight()
                return
            }

            let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            publishVisibleLineRange(for: textView)
            let effectiveDirtyLineRange = dirtyLineRange ?? visibleLineRange
            let shouldSkipDuplicateSchedule =
                lastScheduledHighlightVersion == parent.document.version &&
                lastScheduledVisibleLineRange == visibleLineRange &&
                dirtyLineRange == nil

            guard !shouldSkipDuplicateSchedule else {
                return
            }

            lastScheduledHighlightVersion = parent.document.version
            lastScheduledVisibleLineRange = visibleLineRange

            let documentSnapshot = parent.document
            let request = highlightPipeline.makeViewportRequest(
                document: documentSnapshot,
                language: parent.language,
                visibleLineRange: visibleLineRange,
                dirtyLineRange: effectiveDirtyLineRange,
                appearance: currentAppearance(for: textView),
                fontSize: currentFontSize(for: textView)
            )
            guard !highlightPipeline.shouldSkipRealtimeHighlight(for: request, document: documentSnapshot) else {
                Task {
                    await highlightScheduler.cancel()
                }
                return
            }
            let debounceNanoseconds = parent.highlightDebounceNanoseconds
            let executionDelayNanoseconds = parent.highlightExecutionDelayNanoseconds
            let highlighter = parent.highlighter
            let pipeline = highlightPipeline

            Task {
                await highlightScheduler.schedule(
                    .init(request: request, textSnapshot: documentSnapshot.text),
                    debounceNanoseconds: debounceNanoseconds,
                    execute: { work in
                        if executionDelayNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: executionDelayNanoseconds)
                        }
                        guard !Task.isCancelled else {
                            return nil
                        }
                        return pipeline.highlight(
                            request: work.request,
                            document: documentSnapshot,
                            highlighter: highlighter
                        )
                    },
                    onResult: { [weak self, weak textView] result in
                        guard let self, let textView else { return }
                        await MainActor.run {
                            self.applyHighlightResult(result, to: textView)
                        }
                    }
                )
            }
        }

        func fullDocumentLineRange() -> ClosedRange<Int> {
            1...max(parent.document.lineCount, 1)
        }

        private func cancelHighlight() {
            Task {
                await highlightScheduler.cancel()
            }
        }

        private func commitDisplayedText(
            from textView: CodeEditorPlatformTextView,
            preferPendingEdit: Bool
        ) {
            let currentText = textView.string
            let selectedRange = textView.selectedRange()
            let committedEdit = resolvedCommittedEdit(
                from: parent.document.text,
                to: currentText,
                preferredEdit: preferPendingEdit ? pendingEdit : nil
            )
            let change = parent.document.applyUserEdit(
                replacing: committedEdit.replacedRange,
                insertedText: committedEdit.insertedText,
                updatedText: currentText,
                selectedRange: selectedRange
            )
            pendingEdit = nil
            parent.text = currentText
            parent.onChangeSet?(change)
            publishSelection(for: textView)
            scheduleHighlight(for: textView, dirtyLineRange: dirtyLineRange(for: change))
        }

        private func resolvedCommittedEdit(
            from oldText: String,
            to newText: String,
            preferredEdit: PendingEdit?
        ) -> PendingEdit {
            if let preferredEdit,
               editMatchesTexts(preferredEdit, oldText: oldText, newText: newText) {
                return preferredEdit
            }

            return computeEditDelta(from: oldText, to: newText)
        }

        private func editMatchesTexts(_ edit: PendingEdit, oldText: String, newText: String) -> Bool {
            let oldNSString = oldText as NSString
            guard edit.replacedRange.location >= 0,
                  edit.replacedRange.upperBound <= oldNSString.length else {
                return false
            }

            let candidate = oldNSString.replacingCharacters(in: edit.replacedRange, with: edit.insertedText)
            return candidate == newText
        }

        private func computeEditDelta(from oldText: String, to newText: String) -> PendingEdit {
            let oldNSString = oldText as NSString
            let newNSString = newText as NSString
            let oldLength = oldNSString.length
            let newLength = newNSString.length

            var prefixLength = 0
            while prefixLength < oldLength,
                  prefixLength < newLength,
                  oldNSString.character(at: prefixLength) == newNSString.character(at: prefixLength) {
                prefixLength += 1
            }

            var oldSuffixLength = 0
            let maxSuffixLength = min(oldLength - prefixLength, newLength - prefixLength)
            while oldSuffixLength < maxSuffixLength,
                  oldNSString.character(at: oldLength - oldSuffixLength - 1) == newNSString.character(at: newLength - oldSuffixLength - 1) {
                oldSuffixLength += 1
            }

            let replacedRange = NSRange(
                location: prefixLength,
                length: oldLength - prefixLength - oldSuffixLength
            )
            let insertedText = newNSString.substring(with: NSRange(
                location: prefixLength,
                length: newLength - prefixLength - oldSuffixLength
            ))
            return PendingEdit(replacedRange: replacedRange, insertedText: insertedText)
        }

        private func applyHighlightResult(
            _ result: CodeEditorHighlightResult,
            to textView: CodeEditorPlatformTextView
        ) {
            guard result.version == parent.document.version, !textView.hasMarkedText() else {
                return
            }

            textView.latestHighlightResult = result
            _ = CodeEditorHighlightApplicator.apply(
                result,
                decorations: parent.decorations,
                to: textView,
                baseAttributes: baseAttributes(for: textView)
            )
            textView.latestAppliedHighlightVersion = result.version

            // Pair colorization（opt-in）
            if parent.isBracketPairColorizationEnabled,
               let storage = textView.textStorage {
                let visibleRange: NSRange
                if let visibleLineRange = visibleLineRange(for: textView) {
                    let startOffset = parent.document.utf16Offset(line: visibleLineRange.lowerBound, column: 1)
                    let endOffset = parent.document.utf16Offset(line: visibleLineRange.upperBound, column: 9999)
                    let clampedStart = max(0, startOffset)
                    let clampedEnd = min(endOffset, storage.length)
                    if clampedEnd > clampedStart {
                        visibleRange = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
                    } else {
                        visibleRange = NSRange(location: 0, length: storage.length)
                    }
                } else {
                    visibleRange = NSRange(location: 0, length: storage.length)
                }
                CodeEditorBracketPairColorizationService.colorize(
                    textView: textView,
                    visibleUTF16Range: visibleRange
                )
            }
        }

        func applyCachedHighlightPresentation(to textView: CodeEditorPlatformTextView) {
            guard !textView.hasMarkedText(),
                  let result = textView.latestHighlightResult,
                  result.version == parent.document.version else {
                return
            }

            _ = CodeEditorHighlightApplicator.apply(
                result,
                decorations: parent.decorations,
                to: textView,
                baseAttributes: baseAttributes(for: textView)
            )
            textView.latestAppliedHighlightVersion = result.version
        }

        private func baseAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textView.textColor ?? NSColor.labelColor
            ]
        }

        private func currentAppearance(for textView: NSTextView) -> CodeHighlightAppearance {
            textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }

        private func currentFontSize(for textView: NSTextView) -> CGFloat {
            textView.font?.pointSize ?? NSFont.systemFontSize
        }

        private func visibleLineRange(for textView: NSTextView) -> ClosedRange<Int>? {
            guard
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return nil
            }

            layoutManager.ensureLayout(for: textContainer)
            let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let lineRange: FileLineRange
            if let textView = textView as? CodeEditorPlatformTextView {
                lineRange = textView.displayedLineRange(for: characterRange)
            } else {
                lineRange = parent.document.lineRange(for: characterRange)
            }
            return lineRange.startLine...max(lineRange.endLine, lineRange.startLine)
        }

        private func dirtyLineRange(for change: EditorChangeSet) -> ClosedRange<Int> {
            let insertedLength = (change.insertedText as NSString).length
            let dirtyRange = NSRange(
                location: change.replacedRange.location,
                length: max(change.replacedRange.length, insertedLength)
            )
            let fileLineRange = parent.document.lineRange(for: dirtyRange)
            return fileLineRange.startLine...max(fileLineRange.endLine, fileLineRange.startLine)
        }

        private func selectionSnapshot(for textView: NSTextView, text: String, range: NSRange) -> EditorSelectionSnapshot? {
            let source = text as NSString
            let safeLocation = max(0, min(range.location, source.length))
            let safeLength = max(0, min(range.length, source.length - safeLocation))
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            guard safeRange.length > 0 else {
                return nil
            }

            let selectedText = source.substring(with: safeRange)
            let lineRange: FileLineRange
            if let displayedTextView = textView as? CodeEditorPlatformTextView {
                lineRange = displayedTextView.displayedLineRange(for: safeRange)
            } else {
                lineRange = parent.document.lineRange(for: safeRange)
            }
            return EditorSelectionSnapshot(
                text: selectedText,
                lineRange: lineRange
            )
        }
    }
}

@MainActor
enum CodeEditorHighlightApplicator {
    static func apply(
        _ result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        to textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> Set<Int> {
        guard let storage = textView.textStorage else { return [] }
        let fragmentsByLine = Dictionary(uniqueKeysWithValues: result.lineFragments.map { ($0.line, $0) })
        let changedLines = changedLineSet(
            result: result,
            decorations: decorations,
            textView: textView
        )

        guard changedLines.isEmpty == false else {
            if let textView = textView as? CodeEditorPlatformTextView {
                updateFingerprints(result: result, decorations: decorations, textView: textView)
                textView.lastReappliedLines = []
            }
            return []
        }

        let selectedRange = textView.selectedRange()
        let typingAttributes = textView.typingAttributes

        storage.beginEditing()

        for line in changedLines.sorted() {
            guard let fragment = fragmentsByLine[line], fragment.utf16Range.upperBound <= storage.length else {
                continue
            }

            storage.setAttributes(baseAttributes, range: fragment.utf16Range)
            fragment.attributedString.enumerateAttributes(
                in: NSRange(location: 0, length: fragment.attributedString.length),
                options: []
            ) { attributes, range, _ in
                let targetRange = NSRange(
                    location: fragment.utf16Range.location + range.location,
                    length: range.length
                )
                storage.addAttributes(attributes, range: targetRange)
            }

            for span in decorations.spansByLine[line] ?? [] {
                let safeRange = clampedDecorationRange(span.utf16Range, storageLength: storage.length)
                guard safeRange.length > 0 else {
                    continue
                }
                storage.addAttributes(decorationAttributes(for: span.kind), range: safeRange)
            }
        }

        storage.endEditing()

        textView.setSelectedRange(selectedRange)
        textView.typingAttributes = typingAttributes

        if let textView = textView as? CodeEditorPlatformTextView {
            updateFingerprints(result: result, decorations: decorations, textView: textView)
            textView.lastReappliedLines = changedLines.sorted()
        }

        return changedLines
    }

    private static func changedLineSet(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: NSTextView
    ) -> Set<Int> {
        let newFingerprints = combinedFingerprints(result: result, decorations: decorations)
        guard let textView = textView as? CodeEditorPlatformTextView else {
            return Set(newFingerprints.keys)
        }

        return Set(newFingerprints.compactMap { line, fingerprint in
            textView.appliedLinePresentationFingerprints[line] == fingerprint ? nil : line
        })
    }

    private static func updateFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: CodeEditorPlatformTextView
    ) {
        for (line, fingerprint) in combinedFingerprints(result: result, decorations: decorations) {
            textView.appliedLinePresentationFingerprints[line] = fingerprint
        }
    }

    private static func combinedFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        let decorationFingerprints = decorationFingerprints(for: decorations)
        return Dictionary(uniqueKeysWithValues: result.lineFragments.map { fragment in
            let combined = fragment.fingerprint ^ (decorationFingerprints[fragment.line] ?? 0)
            return (fragment.line, combined)
        })
    }

    private static func decorationFingerprints(
        for decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        decorations.spansByLine.mapValues { spans in
            var hasher = Hasher()
            for span in spans.sorted(by: { lhs, rhs in
                if lhs.utf16Range.location == rhs.utf16Range.location {
                    return lhs.utf16Range.length < rhs.utf16Range.length
                }
                return lhs.utf16Range.location < rhs.utf16Range.location
            }) {
                hasher.combine(span.utf16Range.location)
                hasher.combine(span.utf16Range.length)
                hasher.combine(String(describing: span.kind))
            }
            return hasher.finalize()
        }
    }

    private static func clampedDecorationRange(_ range: NSRange, storageLength: Int) -> NSRange {
        let location = max(0, min(range.location, storageLength))
        let length = max(0, min(range.length, storageLength - location))
        return NSRange(location: location, length: length)
    }

    private static func decorationAttributes(
        for kind: CodeEditorDecorationKind
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .findMatch:
            return [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.28)]
        case .activeFindMatch:
            return [.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.35)]
        case .selectionMatch:
            return [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18)]
        case let .diagnosticUnderline(severity):
            return [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: underlineColor(for: severity)
            ]
        }
    }

    private static func underlineColor(for severity: LSPDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .information:
            return .systemBlue
        case .hint:
            return .systemGray
        }
    }
}

final class CodeEditorPlatformTextView: NSTextView {
    var latestAppliedHighlightVersion: Int?
    var latestHighlightResult: CodeEditorHighlightResult?

    // MARK: - Bracket Match Highlight
    /// 当前已应用的括号高亮范围（用于后续清除）
    private var appliedBracketMatchRanges: (open: NSRange, close: NSRange)?

    /// 括号高亮背景色
    static let bracketMatchBackgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
    var latestDecorationSnapshot: CodeEditorDecorationSnapshot = .empty(version: 0, lineRange: 1...1)
    var currentDocumentVersion: Int = 0
    var compositionStateChangeHandler: ((CodeEditorPlatformTextView) -> Void)?
    var semanticIntentHandler: ((CodeEditorSemanticIntent) -> Void)?
    var findIntentHandler: ((CodeEditorFindIntent) -> Void)?
    var appliedLinePresentationFingerprints: [Int: Int] = [:]
    var lastReappliedLines: [Int] = []
    var highlightedLineNumber: Int? {
        didSet {
            guard highlightedLineNumber != oldValue else {
                return
            }

            invalidateLine(oldValue)
            invalidateLine(highlightedLineNumber)
        }
    }
    private var displayedLineIndex = CodeEditorLineIndex(text: "")
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverPopover = NSPopover()
    private var currentHoverPresentation: CodeEditorHoverPresentation?

    var displayedLineCount: Int {
        displayedLineIndex.lineCount
    }

    var currentHoverMarkdown: String? {
        currentHoverPresentation?.markdown
    }

    var isHoverPopoverShown: Bool {
        hoverPopover.isShown
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        hoverPopover.behavior = .semitransient
        hoverPopover.animates = false
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let line = highlightedLineNumber,
              let lineRect = backgroundRect(forLine: line),
              lineRect.intersects(rect) else {
            return
        }

        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
        lineRect.fill()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshDisplayedTextState()
        compositionStateChangeHandler?(self)
    }

    override func unmarkText() {
        let hadMarkedText = hasMarkedText()
        super.unmarkText()
        guard hadMarkedText else {
            return
        }

        refreshDisplayedTextState()
        compositionStateChangeHandler?(self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
           let position = semanticPosition(at: convert(event.locationInWindow, from: nil)) {
            emitSemanticIntent(.requestDefinition(position))
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        guard let position = semanticPosition(at: convert(event.locationInWindow, from: nil)) else {
            return
        }

        emitSemanticIntent(.requestHover(position))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        emitSemanticIntent(.cancelHover)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 111 {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift),
               let position = semanticPositionForSelection() {
                emitSemanticIntent(.requestReferences(position))
                return
            }

            if let position = semanticPositionForSelection() {
                emitSemanticIntent(.requestDefinition(position))
                return
            }
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            findIntentHandler?(.present)
            return true
        }

        if event.keyCode == 53 {
            findIntentHandler?(.dismiss)
            return true
        }

        if event.keyCode == 36 {
            findIntentHandler?(modifiers.contains(.shift) ? .previousMatch : .nextMatch)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    func refreshDisplayedTextState() {
        displayedLineIndex.replaceAll(with: string)
    }

    func displayedLocation(ofUTF16Offset offset: Int) -> CodeEditorTextLocation {
        displayedLineIndex.location(ofUTF16Offset: offset)
    }

    func displayedLineRange(for characterRange: NSRange) -> FileLineRange {
        displayedLineIndex.lineRange(forUTF16Range: characterRange)
    }

    func visibleLineMetrics(in visibleRect: NSRect) -> [CodeEditorVisibleLineMetric] {
        guard let layoutManager,
              let textContainer,
              let visibleLineRange = displayedVisibleLineRange(in: visibleRect, layoutManager: layoutManager, textContainer: textContainer) else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let baselineOffset = font?.ascender ?? 0

        return visibleLineRange.compactMap { line in
            guard let rect = displayedLineRect(for: line, layoutManager: layoutManager, textContainer: textContainer) else {
                return nil
            }

            return CodeEditorVisibleLineMetric(
                line: line,
                rect: rect,
                baselineY: rect.minY + baselineOffset
            )
        }
    }

    func backgroundRect(forLine line: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        return displayedLineRect(for: line, layoutManager: layoutManager, textContainer: textContainer)
    }

    func emitSemanticIntent(_ intent: CodeEditorSemanticIntent) {
        guard !hasMarkedText() else {
            return
        }

        semanticIntentHandler?(intent)
    }

    func semanticPosition(line: Int, column: Int) -> CodeEditorSemanticPosition {
        let utf16Offset = displayedLineIndex.utf16Offset(line: line, column: column)
        let location = displayedLineIndex.location(ofUTF16Offset: utf16Offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: utf16Offset,
            version: currentDocumentVersion
        )
    }

    func applyRevealRequest(_ request: CodeEditorRevealRequest) {
        let offset = displayedLineIndex.utf16Offset(line: request.line, column: request.column)
        let selectedRange = NSRange(location: offset, length: 0)
        setSelectedRange(selectedRange)
        scrollRangeToVisible(selectedRange)
    }

    func updateHoverPresentation(_ presentation: CodeEditorHoverPresentation?) {
        currentHoverPresentation = presentation

        guard let presentation else {
            if hoverPopover.isShown {
                hoverPopover.performClose(nil)
            }
            return
        }

        guard let anchorRect = hoverAnchorRect(forUTF16Offset: presentation.position.utf16Offset) else {
            return
        }

        let content = Text(presentation.markdown)
            .font(.system(size: 12))
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(maxWidth: 320, alignment: .leading)
        hoverPopover.contentViewController = NSHostingController(rootView: content)

        if hoverPopover.isShown {
            hoverPopover.performClose(nil)
        }

        hoverPopover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
    }

    private func displayedUTF16LineRange(forLine line: Int) -> NSRange {
        let safeLine = max(1, min(line, displayedLineIndex.lineCount))
        let startOffset = displayedLineIndex.lineStartOffset(forLine: safeLine)
        let endOffset = safeLine < displayedLineIndex.lineCount
            ? displayedLineIndex.lineStartOffset(forLine: safeLine + 1)
            : (string as NSString).length

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    private func displayedVisibleLineRange(
        in visibleRect: NSRect,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> ClosedRange<Int>? {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lineRange = displayedLineRange(for: characterRange)
        return lineRange.startLine...max(lineRange.endLine, lineRange.startLine)
    }

    private func displayedLineRect(
        for line: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if layoutManager.numberOfGlyphs == 0 {
            let origin = textContainerOrigin
            let height = layoutManager.defaultLineHeight(for: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            return NSRect(x: 0, y: origin.y, width: bounds.width, height: height).integral
        }

        let characterRange = displayedUTF16LineRange(forLine: line)
        let safeLength: Int
        let safeLocation: Int
        if characterRange.length == 0 {
            safeLocation = max(0, min(characterRange.location, (string as NSString).length))
            safeLength = 0
        } else {
            safeLocation = characterRange.location
            safeLength = characterRange.length
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeLocation, length: safeLength),
            actualCharacterRange: nil
        )

        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.isEmpty {
            let fallbackLocation = max(0, min(safeLocation, (string as NSString).length))
            let fallbackGlyphIndex = layoutManager.glyphIndexForCharacter(at: fallbackLocation)
            rect = layoutManager.lineFragmentRect(forGlyphAt: fallbackGlyphIndex, effectiveRange: nil)
        }

        guard !rect.isEmpty else {
            return nil
        }

        let origin = textContainerOrigin
        rect.origin.x = 0
        rect.origin.y += origin.y
        rect.size.width = bounds.width
        return rect.integral
    }

    private func invalidateLine(_ line: Int?) {
        guard let line,
              let rect = backgroundRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }

    private func semanticPosition(at point: NSPoint) -> CodeEditorSemanticPosition? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let safeOffset = max(0, min(characterIndex, (string as NSString).length))
        let location = displayedLineIndex.location(ofUTF16Offset: safeOffset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: safeOffset,
            version: currentDocumentVersion
        )
    }

    private func semanticPositionForSelection() -> CodeEditorSemanticPosition? {
        let offset = max(0, min(selectedRange().location, (string as NSString).length))
        let location = displayedLineIndex.location(ofUTF16Offset: offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: offset,
            version: currentDocumentVersion
        )
    }

    private func hoverAnchorRect(forUTF16Offset offset: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let safeOffset = max(0, min(offset, (string as NSString).length))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeOffset, length: 0),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.isEmpty {
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        }
        guard rect.isEmpty == false else {
            return nil
        }

        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        rect.size.width = max(rect.width, 1)
        rect.size.height = max(rect.height, font?.pointSize ?? NSFont.systemFontSize)
        return rect.integral
    }

    // MARK: - Bracket Match Highlight

    /// 应用括号高亮（清除旧的后应用新的）。
    /// 若 result 为 nil 则只清除旧高亮。
    func applyBracketMatchHighlight(_ result: CodeEditorBracketMatchResult?) {
        guard let layoutManager else { return }
        // 清除旧的高亮
        if let old = appliedBracketMatchRanges {
            let fullLength = (string as NSString).length
            let safeOpen = clampRange(old.open, max: fullLength)
            let safeClose = clampRange(old.close, max: fullLength)
            if safeOpen.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeOpen)
            }
            if safeClose.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeClose)
            }
        }
        appliedBracketMatchRanges = nil

        guard let result else { return }
        let fullLength = (string as NSString).length
        let safeOpen = clampRange(result.openRange, max: fullLength)
        let safeClose = clampRange(result.closeRange, max: fullLength)
        guard safeOpen.length > 0, safeClose.length > 0 else { return }

        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Self.bracketMatchBackgroundColor,
            forCharacterRange: safeOpen
        )
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Self.bracketMatchBackgroundColor,
            forCharacterRange: safeClose
        )
        appliedBracketMatchRanges = (safeOpen, safeClose)
    }

    private func clampRange(_ range: NSRange, max length: Int) -> NSRange {
        let location = Swift.max(0, Swift.min(range.location, length))
        let safeLength = Swift.max(0, Swift.min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }
}

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}