import AppKit
import SwiftUI

struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var language: String? = nil
    var focusRequest: UUID? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onCursorLocationChange: ((CodeEditorTextLocation) -> Void)? = nil
    var onVisibleLineRangeChange: ((ClosedRange<Int>) -> Void)? = nil
    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] = [:]
    var onChangeSet: ((EditorChangeSet) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
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
        textView.setAccessibilityIdentifier("codeEditor.textView")
        textView.highlightedLineNumber = document.location(ofUTF16Offset: document.selectedRange.location).line
        textView.compositionStateChangeHandler = { [weak coordinator = context.coordinator] textView in
            coordinator?.handleCompositionStateChange(in: textView)
        }

        scrollView.documentView = textView
        context.coordinator.installGutter(for: scrollView, textView: textView)
        context.coordinator.installSelectionObserver(for: textView)
        context.coordinator.installViewportObserver(for: scrollView, textView: textView)
        context.coordinator.publishSelection(for: textView)
        context.coordinator.publishVisibleLineRange(for: textView)
        context.coordinator.updateGutterState(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeEditorPlatformTextView else { return }
        context.coordinator.parent = self
        context.coordinator.installGutter(for: scrollView, textView: textView)

        if !textView.hasMarkedText(), textView.string != text {
            let selectedRange = clampedRange(document.selectedRange, for: text)
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.string = text
            textView.refreshDisplayedTextState()
            textView.setSelectedRange(selectedRange)
            context.coordinator.isApplyingProgrammaticUpdate = false
            textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: selectedRange.location).line
            context.coordinator.publishVisibleLineRange(for: textView)
            context.coordinator.updateGutterState(for: textView)
            context.coordinator.scheduleHighlight(
                for: textView,
                dirtyLineRange: context.coordinator.fullDocumentLineRange()
            )
        }

        textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: textView.selectedRange().location).line
        context.coordinator.updateGutterState(for: textView)

        context.coordinator.scheduleHighlight(for: textView, dirtyLineRange: nil)

        if let focusRequest,
           context.coordinator.lastAppliedFocusRequest != focusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            context.coordinator.applyFocus(to: textView)
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
        private var selectionObserver: NSObjectProtocol?
        private var viewportObserver: NSObjectProtocol?
        private var pendingEdit: PendingEdit?
        private let highlightScheduler = CodeEditorHighlightScheduler()
        private let highlightPipeline = CodeEditorHighlightPipeline()
        private var lastScheduledHighlightVersion: Int?
        private var lastScheduledVisibleLineRange: ClosedRange<Int>?
        private var lastPublishedVisibleLineRange: ClosedRange<Int>?

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
                cancelHighlight()
                return
            }

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
                self.publishSelection(for: textView)
            }
        }

        func installGutter(for scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
            if scrollView.verticalRulerView as? CodeEditorGutterView == nil {
                let gutterView = CodeEditorGutterView(
                    scrollView: scrollView,
                    textView: textView,
                    lineCount: textView.displayedLineCount
                )
                scrollView.verticalRulerView = gutterView
            }

            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            scrollView.verticalRulerView?.clientView = textView
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
                  let gutterView = textView.enclosingScrollView?.verticalRulerView as? CodeEditorGutterView else {
                return
            }

            let visibleRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            gutterView.updateLayoutState(
                lineCount: textView.displayedLineCount,
                visibleLineRange: visibleRange,
                currentLine: textView.highlightedLineNumber,
                diagnosticsByLine: parent.diagnosticsByLine
            )
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

            CodeEditorHighlightApplicator.apply(
                result,
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
        to textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) {
        guard let storage = textView.textStorage else { return }
        guard result.replacementRange.upperBound <= storage.length else { return }
        guard result.attributedString.length == result.replacementRange.length else { return }

        let selectedRange = textView.selectedRange()
        let typingAttributes = textView.typingAttributes

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: result.replacementRange)
        result.attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: result.attributedString.length),
            options: []
        ) { attributes, range, _ in
            let targetRange = NSRange(
                location: result.replacementRange.location + range.location,
                length: range.length
            )
            storage.addAttributes(attributes, range: targetRange)
        }
        storage.endEditing()

        textView.setSelectedRange(selectedRange)
        textView.typingAttributes = typingAttributes
    }
}

final class CodeEditorPlatformTextView: NSTextView {
    var latestAppliedHighlightVersion: Int?
    var compositionStateChangeHandler: ((CodeEditorPlatformTextView) -> Void)?
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

    var displayedLineCount: Int {
        displayedLineIndex.lineCount
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

    func refreshDisplayedTextState() {
        displayedLineIndex.replaceAll(with: string)
    }

    func displayedLocation(ofUTF16Offset offset: Int) -> CodeEditorTextLocation {
        displayedLineIndex.location(ofUTF16Offset: offset)
    }

    func displayedLineRange(for characterRange: NSRange) -> FileLineRange {
        displayedLineIndex.lineRange(forUTF16Range: characterRange)
    }

    func backgroundRect(forLine line: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

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

        layoutManager.ensureLayout(for: textContainer)

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

    private func displayedUTF16LineRange(forLine line: Int) -> NSRange {
        let safeLine = max(1, min(line, displayedLineIndex.lineCount))
        let startOffset = displayedLineIndex.lineStartOffset(forLine: safeLine)
        let endOffset = safeLine < displayedLineIndex.lineCount
            ? displayedLineIndex.lineStartOffset(forLine: safeLine + 1)
            : (string as NSString).length

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    private func invalidateLine(_ line: Int?) {
        guard let line,
              let rect = backgroundRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }
}

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}