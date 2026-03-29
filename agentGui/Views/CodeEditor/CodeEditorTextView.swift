import AppKit
import SwiftUI

struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var focusRequest: UUID? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onChangeSet: ((EditorChangeSet) -> Void)? = nil

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

        let textView = NSTextView()
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            let selectedRange = clampedRange(document.selectedRange, for: text)
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.string = text
            textView.setSelectedRange(selectedRange)
            context.coordinator.isApplyingProgrammaticUpdate = false
        }

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
        private var pendingEdit: PendingEdit?

        init(_ parent: CodeEditorTextView) {
            self.parent = parent
        }

        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
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
            guard let textView = notification.object as? NSTextView else { return }
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

        private func selectionSnapshot(text: String, range: NSRange) -> EditorSelectionSnapshot? {
            let source = text as NSString
            let safeLocation = max(0, min(range.location, source.length))
            let safeLength = max(0, min(range.length, source.length - safeLocation))
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            guard safeRange.length > 0 else {
                return nil
            }

            let selectedText = source.substring(with: safeRange)
            let textBeforeSelection = source.substring(to: safeRange.location)
            let startLine = newlineCount(in: textBeforeSelection) + 1
            let endLine = startLine + newlineCount(in: selectedText)
            return EditorSelectionSnapshot(
                text: selectedText,
                lineRange: FileLineRange(startLine: startLine, endLine: endLine)
            )
        }

        private func newlineCount(in text: String) -> Int {
            text.reduce(into: 0) { count, character in
                if character == "\n" {
                    count += 1
                }
            }
        }
    }
}

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}