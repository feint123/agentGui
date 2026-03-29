import AppKit
import SwiftUI

struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var language: String? = nil
    var focusRequest: UUID? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
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
        textView.setAccessibilityIdentifier("codeEditor.textView")

        scrollView.documentView = textView
        context.coordinator.installSelectionObserver(for: textView)
        context.coordinator.installViewportObserver(for: scrollView, textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeEditorPlatformTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            let selectedRange = clampedRange(document.selectedRange, for: text)
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.string = text
            textView.setSelectedRange(selectedRange)
            context.coordinator.isApplyingProgrammaticUpdate = false
            context.coordinator.scheduleHighlight(
                for: textView,
                dirtyLineRange: context.coordinator.fullDocumentLineRange()
            )
        }

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
        private var lastObservedVisibleLineRange: ClosedRange<Int>?

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

            let currentText = textView.string
            let selectedRange = textView.selectedRange()
            let change = parent.document.applyUserEdit(
                replacing: pendingEdit?.replacedRange ?? NSRange(location: 0, length: parent.document.text.utf16.count),
                insertedText: pendingEdit?.insertedText ?? currentText,
                updatedText: currentText,
                selectedRange: selectedRange
            )
            pendingEdit = nil
            parent.text = currentText
            parent.onChangeSet?(change)
            publishSelection(for: textView)
            scheduleHighlight(for: textView, dirtyLineRange: dirtyLineRange(for: change))
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
            let snapshot = selectionSnapshot(text: textView.string, range: selectedRange)
            parent.onSelectionChange?(snapshot)
            DispatchQueue.main.async { [self] in
                parent.document.markSelection(selectedRange)
            }
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
            let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            let effectiveDirtyLineRange = dirtyLineRange ?? visibleLineRange
            let shouldSkipDuplicateSchedule =
                lastScheduledHighlightVersion == parent.document.version &&
                lastScheduledVisibleLineRange == visibleLineRange &&
                dirtyLineRange == nil

            guard !shouldSkipDuplicateSchedule else {
                return
            }

            lastObservedVisibleLineRange = visibleLineRange
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

        private func applyHighlightResult(
            _ result: CodeEditorHighlightResult,
            to textView: CodeEditorPlatformTextView
        ) {
            guard result.version == parent.document.version else {
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
            let lineRange = parent.document.lineRange(for: characterRange)
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

        private func selectionSnapshot(text: String, range: NSRange) -> EditorSelectionSnapshot? {
            let source = text as NSString
            let safeLocation = max(0, min(range.location, source.length))
            let safeLength = max(0, min(range.length, source.length - safeLocation))
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            guard safeRange.length > 0 else {
                return nil
            }

            let selectedText = source.substring(with: safeRange)
            return EditorSelectionSnapshot(
                text: selectedText,
                lineRange: parent.document.lineRange(for: safeRange)
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
}

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}