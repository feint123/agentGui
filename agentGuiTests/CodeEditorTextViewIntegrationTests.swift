import AppKit
import Foundation
import Testing
@testable import agentGui

@MainActor
struct CodeEditorTextViewIntegrationTests {
    @Test
    func userEditUpdatesBindingAndEmitsChangeSet() {
        let harness = CodeEditorTextViewHarness(text: "hello")

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: " world")

        #expect(harness.boundText == "hello world")
        #expect(harness.document.text == "hello world")
        #expect(harness.lastChangeSet?.replacedRange == NSRange(location: 5, length: 0))
        #expect(harness.lastChangeSet?.insertedText == " world")
        #expect(harness.lastChangeSet?.origin == .userEdit)
    }

    @Test
    func selectionChangePublishesSelectionSnapshot() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

        harness.select(range: NSRange(location: 6, length: 4))

        #expect(harness.lastSelection?.text == "beta")
        #expect(harness.lastSelection?.lineRange == FileLineRange(startLine: 2, endLine: 2))
    }

    @Test
    func selectionSnapshotUsesUpdatedLineIndexAfterEdit() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta")

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "\n")
        harness.clearRecordedCallbacks()
        harness.select(range: NSRange(location: 6, length: 0))

        #expect(harness.document.lineRange(for: NSRange(location: 6, length: 0)) == FileLineRange(startLine: 2, endLine: 2))
        #expect(harness.lastSelection == nil)

        harness.select(range: NSRange(location: 7, length: 4))

        #expect(harness.lastSelection?.text == "beta")
        #expect(harness.lastSelection?.lineRange == FileLineRange(startLine: 3, endLine: 3))
    }

    @Test
    func selectionChangePublishesCurrentCursorLocation() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

        harness.select(range: NSRange(location: 7, length: 0))

        #expect(harness.lastCursorLocation == CodeEditorTextLocation(line: 2, column: 2))
        #expect(harness.highlightedLine == 2)
    }

    @Test
    func viewportPublishesVisibleLineRange() {
        let text = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let harness = CodeEditorTextViewHarness(text: text)

        #expect(harness.lastVisibleLineRange?.contains(1) == true)

        harness.scrollToLine(30)

        #expect(harness.lastVisibleLineRange?.contains(30) == true)
    }

    @Test
    func textViewExportsVisibleLineMetricsForViewport() {
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let harness = CodeEditorTextViewHarness(text: text)

        let metrics = harness.visibleLineMetricsForCurrentViewport()

        #expect(metrics.isEmpty == false)
        #expect(metrics.allSatisfy { harness.lastVisibleLineRange?.contains($0.line) == true })
        #expect(metrics.allSatisfy { $0.rect.height > 0 })
        #expect(metrics == metrics.sorted { $0.line < $1.line })
    }

    @Test
    func textViewUsesCustomGutterHostInsteadOfVerticalRuler() {
        let harness = CodeEditorTextViewHarness(text: "one\ntwo\nthree")

        #expect(harness.scrollView.hasVerticalRuler == false)
        #expect(harness.scrollView.verticalRulerView == nil)
        #expect(harness.gutterView != nil)
        #expect(harness.containerView != nil)
        #expect(harness.gutterView?.superview === harness.containerView)
        #expect(harness.gutterView?.superview !== harness.scrollView)
    }

    @Test
    func diagnosticsUpdateReachesGutterWhileCurrentLineRemainsHighlighted() {
        let harness = CodeEditorTextViewHarness(text: "one\ntwo\nthree")

        harness.select(range: NSRange(location: 5, length: 0))
        harness.updateDiagnosticsByLine([
            3: CodeEditorLineDiagnosticSummary(highestSeverity: .warning, messageCount: 1)
        ])

        #expect(harness.highlightedLine == 2)
        #expect(harness.gutterView?.currentLine == 2)
        #expect(harness.gutterView?.diagnosticsByLine[3]?.highestSeverity == .warning)
    }

    @Test
    func gutterWidthExpandsWhenLineCountCrossesDigitBoundary() {
        let harness = CodeEditorTextViewHarness(text: (1...99).map { "line \($0)" }.joined(separator: "\n"))
        let beforeWidth = harness.gutterView?.frame.width ?? 0

        harness.updateFromHost(text: (1...100).map { "line \($0)" }.joined(separator: "\n"))

        #expect((harness.gutterView?.frame.width ?? 0) > beforeWidth)
    }

    @Test
    func gutterConsumesViewportLineMetricsSnapshot() {
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let harness = CodeEditorTextViewHarness(text: text)

        harness.scrollToLine(40)

        #expect(harness.gutterLineMetrics.contains { $0.line == 40 })
        #expect(harness.gutterLineMetrics.first(where: { $0.line == 40 })?.rect.height ?? 0 > 0)
        #expect(harness.gutterLineMetrics.first(where: { $0.line == 40 })?.rect == harness.convertedVisibleLineMetricForCurrentViewport(line: 40)?.rect)
    }

    @Test
    func scrollingAndDiagnosticsUpdateDoNotResetCursorOrText() {
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let harness = CodeEditorTextViewHarness(text: text)
        let cursorOffset = harness.document.utf16Offset(line: 40, column: 2)

        harness.select(range: NSRange(location: cursorOffset, length: 0))
        harness.scrollToLine(60)
        harness.updateDiagnosticsByLine([
            60: CodeEditorLineDiagnosticSummary(highestSeverity: .error, messageCount: 2)
        ])

        #expect(harness.boundText == text)
        #expect(harness.highlightedLine == 40)
        #expect(harness.lastCursorLocation == CodeEditorTextLocation(line: 40, column: 2))
        #expect(harness.gutterView?.diagnosticsByLine[60]?.highestSeverity == .error)
    }

    @Test
    func programmaticTextUpdateDoesNotEmitUserChange() {
        let harness = CodeEditorTextViewHarness(text: "old")
        harness.clearRecordedCallbacks()

        harness.updateFromHost(text: "fresh", persistedText: "fresh")

        #expect(harness.boundText == "fresh")
        #expect(harness.document.text == "fresh")
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastChangeSet == nil)
    }

    @Test
    func markedTextDoesNotSyncTransientCompositionIntoHostDocument() {
        let harness = CodeEditorTextViewHarness(text: "")

        harness.setMarkedText(
            "输入中文",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "输入中文")
        #expect(harness.boundText.isEmpty)
        #expect(harness.document.text.isEmpty)

        harness.updateFromHost(text: "", persistedText: "")

        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "输入中文")

        harness.commitMarkedText()

        #expect(harness.boundText == "输入中文")
        #expect(harness.document.text == "输入中文")
    }

    @Test
    func gutterGeometryTracksDisplayedTextWhileMarkedTextAddsLineBreak() {
        let harness = CodeEditorTextViewHarness(text: "one\ntwo")

        harness.setMarkedText(
            "\n三",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: harness.textView.string.utf16.count, length: 0)
        )

        #expect(harness.textView.hasMarkedText())
        #expect(harness.displayedLineCount == 3)
        #expect(harness.lastVisibleLineRange?.contains(3) == true)
        #expect(harness.visibleLineMetricsForCurrentViewport().contains { $0.line == 3 })
        #expect(harness.gutterLineMetrics.contains { $0.line == 3 })
        #expect(harness.gutterLineMetrics.first(where: { $0.line == 3 })?.rect == harness.convertedVisibleLineMetricForCurrentViewport(line: 3)?.rect)
    }

    @Test
    func emptyDocumentExportsViewportMetricsFallbackLine() {
        let harness = CodeEditorTextViewHarness(text: "")

        let metrics = harness.visibleLineMetricsForCurrentViewport()

        #expect(metrics.isEmpty == false)
        #expect(metrics.first?.line == 1)
        #expect(metrics.first?.rect.height ?? 0 > 0)
    }

    @Test
    func staleHighlightResultDoesNotOverwriteNewerVersionAttributes() {
        let harness = CodeEditorTextViewHarness(
            text: "let a = 1",
            highlightExecutionDelayNanoseconds: 120_000_000
        )

        harness.replaceCharacters(in: NSRange(location: 4, length: 1), with: "b")
        harness.replaceCharacters(in: NSRange(location: 4, length: 1), with: "c")
        harness.waitForHighlightPass()

        #expect(harness.boundText == "let c = 1")
        #expect(harness.latestAppliedHighlightVersion == harness.document.version)
    }

    @Test
    func textViewEnablesUndoAndSetsAccessibilityIdentifier() {
        let harness = CodeEditorTextViewHarness(text: "hello")

        #expect(harness.textView.allowsUndo)
        #expect(harness.textView.accessibilityIdentifier() == "codeEditor.textView")
    }

    @Test
    func applyingHighlightPreservesTypingAttributes() {
        let harness = CodeEditorTextViewHarness(text: "let value = 1", language: "swift")
        let before = harness.textView.typingAttributes

        harness.forceApplyHighlightResult()

        #expect(NSDictionary(dictionary: harness.textView.typingAttributes).isEqual(to: before))
    }

    @Test
    func applyingHighlightPreservesCurrentLineHighlight() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma", language: "swift")

        harness.select(range: NSRange(location: 7, length: 0))
        harness.forceApplyHighlightResult()

        #expect(harness.highlightedLine == 2)
    }

    @MainActor
    @Test
    func decorationOnlyChangeReappliesAffectedLinesOnly() {
        let harness = CodeEditorTextViewHarness(text: "alpha beta\nalpha gamma\nomega", language: "swift")
        let document = harness.document
        let fragments = makeFragments(document: document, lines: 1...3)
        let emptyDecorations = CodeEditorDecorationSnapshot.empty(version: document.version, lineRange: 1...3)

        _ = CodeEditorHighlightApplicator.apply(
            CodeEditorHighlightResult(version: document.version, lineRange: 1...3, lineFragments: fragments),
            decorations: emptyDecorations,
            to: harness.textView,
            baseAttributes: baseAttributes(for: harness.textView)
        )

        let changedLines = CodeEditorHighlightApplicator.apply(
            CodeEditorHighlightResult(version: document.version, lineRange: 1...3, lineFragments: fragments),
            decorations: CodeEditorDecorationSnapshot(
                version: document.version,
                lineRange: 1...3,
                spansByLine: [
                    2: [CodeEditorDecorationSpan(
                        utf16Range: NSRange(location: 11, length: 5),
                        line: 2,
                        kind: .findMatch
                    )]
                ]
            ),
            to: harness.textView,
            baseAttributes: baseAttributes(for: harness.textView)
        )

        #expect(changedLines == Set([2]))
        #expect(Set(harness.textView.lastReappliedLines) == Set([2]))
    }

    @Test
    func findShortcutAndEscapeEmitFindIntentsWithoutEditingDocument() {
        let harness = CodeEditorTextViewHarness(text: "alpha beta alpha")

        harness.sendFindShortcut()
        harness.sendEscape()

        #expect(harness.findIntents == [.present, .dismiss])
        #expect(harness.changeSetCount == 0)
        #expect(harness.boundText == "alpha beta alpha")
    }

    @Test
    func releasingHarnessWithPendingHighlightDoesNotCrash() {
        var harness: CodeEditorTextViewHarness? = CodeEditorTextViewHarness(
            text: "let value = 1",
            language: "swift",
            highlightExecutionDelayNanoseconds: 500_000_000
        )

        harness?.replaceCharacters(in: NSRange(location: 4, length: 5), with: "result")
        harness = nil

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(Bool(true))
    }

    @Test
    func optionClickPublishesDefinitionSemanticIntent() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

        harness.optionClick(line: 2, column: 2)

        #expect(harness.semanticIntents.last == .requestDefinition(.init(line: 2, column: 2, utf16Offset: 7, version: 0)))
    }

    @Test
    func semanticIntentUsesCurrentDocumentVersionBeforeHighlightFinishes() {
        let harness = CodeEditorTextViewHarness(
            text: "alpha",
            highlightExecutionDelayNanoseconds: 500_000_000
        )

        harness.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        harness.clearRecordedCallbacks()
        harness.optionClick(line: 1, column: 6)

        #expect(harness.document.version == 1)
        #expect(harness.semanticIntents.last == .requestDefinition(.init(line: 1, column: 6, utf16Offset: 5, version: 1)))
    }

    @Test
    func shiftF12PublishesReferencesSemanticIntent() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta")
        harness.select(range: NSRange(location: 6, length: 0))

        harness.pressReferencesShortcut()

        #expect(harness.semanticIntents.last == .requestReferences(.init(line: 2, column: 1, utf16Offset: 6, version: 0)))
    }

    @Test
    func hoverAndSubsequentInputEmitHoverThenCancelIntent() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta")

        harness.moveMouse(line: 1, column: 3)
        harness.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        #expect(harness.semanticIntents.contains(.requestHover(.init(line: 1, column: 3, utf16Offset: 2, version: 0))))
        #expect(harness.semanticIntents.last == .cancelHover)
    }

    @Test
    func revealRequestSelectsRequestedLocationWithoutEmittingUserEdit() {
        let harness = CodeEditorTextViewHarness(text: "alpha\nbeta\ngamma")

        harness.applyRevealRequest(
            .init(
                fileURL: URL(fileURLWithPath: "/tmp/Demo.swift"),
                line: 3,
                column: 2,
                reason: .definition
            )
        )

        #expect(harness.textView.selectedRange().location == harness.document.utf16Offset(line: 3, column: 2))
        #expect(harness.changeSetCount == 0)
        #expect(harness.lastCursorLocation == CodeEditorTextLocation(line: 3, column: 2))
    }

    @Test
    func markedTextBlocksSemanticIntentEmission() {
        let harness = CodeEditorTextViewHarness(text: "alpha")

        harness.setMarkedText(
            "输入",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )
        harness.clearRecordedCallbacks()
        harness.optionClick(line: 1, column: 1)
        harness.moveMouse(line: 1, column: 1)
        harness.pressDefinitionShortcut()

        #expect(harness.semanticIntents.isEmpty)
    }
}

private func makeFragments(
    document: CodeEditorDocument,
    lines: ClosedRange<Int>
) -> [CodeEditorStyledLineFragment] {
    let source = document.text as NSString
    return lines.map { line in
        let range = document.utf16LineRange(forLine: line)
        let string = source.substring(with: range)
        return CodeEditorStyledLineFragment(
            line: line,
            utf16Range: range,
            attributedString: NSAttributedString(string: string),
            fingerprint: line * 100 + range.length
        )
    }
}

private func baseAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
    [
        .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .foregroundColor: textView.textColor ?? NSColor.labelColor
    ]
}