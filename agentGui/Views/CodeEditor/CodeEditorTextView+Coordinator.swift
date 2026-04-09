import AppKit

extension CodeEditorTextView {
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorTextView
        var isApplyingProgrammaticUpdate = false
        var lastAppliedFocusRequest: UUID?
        var lastAppliedRevealRequestID: UUID?
        private var selectionObserver: NSObjectProtocol?
        private var viewportObserver: NSObjectProtocol?
        private var pendingEdit: PendingEdit?
        private var isMultiCursorEdit = false
        private let highlightScheduler = CodeEditorHighlightScheduler()
        private let highlightPipeline = CodeEditorHighlightPipeline()
        private var lastScheduledHighlightVersion: Int?
        private var lastScheduledVisibleLineRange: ClosedRange<Int>?
        private var lastPublishedVisibleLineRange: ClosedRange<Int>?
        private var pendingPostUpdateRefreshID: UUID?

        // MARK: - Completion
        let completionTrigger = CodeEditorCompletionTrigger()
        var completionPanel: CodeEditorCompletionPanel?
        var isInIMEComposition = false

        // MARK: - Signature Help
        let signatureHelpTrigger = CodeEditorSignatureHelpTrigger()
        var signatureHelpPanel: CodeEditorSignatureHelpPanel?

        // MARK: - Inlay Hints
        weak var installedInlayHintsCoordinator: CodeEditorLSPCoordinator?
        var lastScheduledInlayHintRange: ClosedRange<Int>?
        var lastScheduledInlayHintVersion: Int?

        // MARK: - Ghost Text
        var ghostTextTrigger: CodeEditorGhostTextTrigger?
        var ghostTextService: CodeEditorGhostTextService?

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

        // MARK: - NSTextViewDelegate

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
                return true
            }

            (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

            pendingEdit = PendingEdit(
                replacedRange: affectedCharRange,
                insertedText: replacementString ?? ""
            )
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
                return true
            }

            (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

            if affectedRanges.count > 1 {
                // 多光标编辑：标记回退到全文差分路径
                isMultiCursorEdit = true
                pendingEdit = nil
            } else {
                isMultiCursorEdit = false
                if let range = affectedRanges.first?.rangeValue {
                    pendingEdit = PendingEdit(
                        replacedRange: range,
                        insertedText: replacementStrings?.first ?? ""
                    )
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeEditorPlatformTextView else { return }
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
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

            // F19: Completion trigger (after user edit, not IME)
            guard !isInIMEComposition, !textView.hasMarkedText() else { return }
            if parent.isCompletionEnabled,
               let lspCoordinator = parent.lspCoordinator,
               let caps = lspCoordinator.capabilities,
               caps.supportsCompletion {
                let cursorOffset = textView.selectedRange().location
                let prefixWord = textView.prefixWordBeforeCursor()
                let lastTyped = textView.lastTypedCharacter ?? ""
                completionTrigger.handleTyping(
                    char: lastTyped,
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    triggerCharacters: caps.completionTriggerCharacters
                )
            }

            // L5: Signature help trigger
            if parent.isSignatureHelpEnabled,
               let lspCoordinator = parent.lspCoordinator,
               let caps = lspCoordinator.capabilities,
               caps.supportsSignatureHelp {
                let cursorOffset = textView.selectedRange().location
                let lastTyped = textView.lastTypedCharacter ?? ""
                signatureHelpTrigger.handleTyping(
                    char: lastTyped,
                    cursorOffset: cursorOffset,
                    triggerCharacters: caps.signatureHelpTriggerCharacters,
                    retriggerCharacters: caps.signatureHelpRetriggerCharacters
                )
            }

            // F23: Ghost text trigger（LSP 补全面板未显示时才触发）
            let completionPanelVisible = completionPanel?.panel.isVisible ?? false
            ghostTextTrigger?.handleChange(
                isIMEActive: textView.hasMarkedText(),
                isGhostTextEnabled: parent.isGhostTextEnabled && !completionPanelVisible,
                contextProvider: { [weak textView] in
                    textView?.extractGhostTextContext(language: self.parent.language)
                }
            )
        }

        func handleCompositionStateChange(in textView: CodeEditorPlatformTextView) {
            guard !isApplyingProgrammaticUpdate else {
                return
            }

            publishSelection(for: textView)
            publishVisibleLineRange(for: textView)
            updateGutterState(for: textView)

            // Track IME composition state for completion suppression
            isInIMEComposition = textView.hasMarkedText()
            if isInIMEComposition {
                completionTrigger.dismiss()
            }

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

        // MARK: - Setup

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
            containerView.gutterView.onGutterLaneHit = { [weak self] hitResult in
                self?.parent.onGutterLaneHit?(hitResult)
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

        // MARK: - Selection & Gutter

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

            // 多光标行高亮
            if let platformTextView = textView as? CodeEditorPlatformTextView {
                let cursorLines = Set(
                    platformTextView.selectedRanges.map { $0.rangeValue }.map { range -> Int in
                        platformTextView.displayedLocation(ofUTF16Offset: range.location + range.length).line
                    }
                )
                platformTextView.highlightedLineNumbers = cursorLines
            } else {
                (textView as? CodeEditorPlatformTextView)?.highlightedLineNumber = cursorLocation.line
            }

            updateGutterState(for: textView)

            // 多光标时更新全选区快照
            let allRanges = textView.selectedRanges.map { $0.rangeValue }
            if allRanges.count > 1 {
                parent.document.markMultiSelection(allRanges)
            } else {
                parent.document.markSelection(selectedRange)
            }

            // 括号高亮（仅单光标时处理）
            if let platformTextView = textView as? CodeEditorPlatformTextView,
               !platformTextView.hasMarkedText(),
               platformTextView.selectedRanges.count <= 1 {
                let cursorOffset = textView.selectedRange().location
                let matchResult = CodeEditorBracketScanner.findMatch(
                    in: platformTextView.string,
                    cursorOffset: cursorOffset
                )
                platformTextView.applyBracketMatchHighlight(matchResult)
            } else if let platformTextView = textView as? CodeEditorPlatformTextView,
                      platformTextView.selectedRanges.count > 1 {
                // 多光标时清除括号高亮
                platformTextView.applyBracketMatchHighlight(nil)
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
            // Use document coordinates directly – the gutter's bounds.origin.y
            // is synced with the scroll view's content offset, so document-space
            // Y values produce correct visual alignment without conversion.
            let lineMetrics = textView.visibleLineMetrics(in: scrollView.contentView.bounds).map { metric in
                CodeEditorVisibleLineMetric(
                    line: metric.line,
                    rect: NSRect(x: 0, y: metric.rect.minY, width: gutterView.requiredWidth, height: metric.rect.height).integral,
                    baselineY: metric.baselineY
                )
            }
            let snapshot = CodeEditorGutterLineMetricsSnapshot(
                lineCount: textView.displayedLineCount,
                visibleLineRange: visibleRange,
                currentLine: textView.highlightedLineNumber,
                cursorLineNumbers: textView.highlightedLineNumbers,
                lineMetrics: lineMetrics,
                diagnosticsByLine: parent.diagnosticsByLine,
                gitDiffByLine: parent.gitDiffByLine,
                agentChangeDiffByLine: parent.agentChangeDiffByLine
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

        // MARK: - Focus & Reveal

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

        // MARK: - Highlight Scheduling

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

            // 高亮调度完成后同步触发 inlay hint 调度
            if parent.isInlayHintsEnabled {
                scheduleInlayHintRequest(for: textView)
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

        // MARK: - Text Commit

        private func commitDisplayedText(
            from textView: CodeEditorPlatformTextView,
            preferPendingEdit: Bool
        ) {
            let currentText = textView.string
            let selectedRange = textView.selectedRange()

            // 多光标编辑：pendingEdit 无效，直接全文更新
            if isMultiCursorEdit {
                isMultiCursorEdit = false
                pendingEdit = nil
                let changeSet = parent.document.replaceAllForMultiCursorEdit(
                    text: currentText,
                    selectedRange: selectedRange
                )
                parent.text = currentText
                parent.onChangeSet?(changeSet)
                publishSelection(for: textView)
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                scheduleHighlight(for: textView, dirtyLineRange: nil)
                return
            }

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

        // MARK: - Highlight Application

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

        // MARK: - Helpers

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

        func visibleLineRange(for textView: NSTextView) -> ClosedRange<Int>? {
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

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}
