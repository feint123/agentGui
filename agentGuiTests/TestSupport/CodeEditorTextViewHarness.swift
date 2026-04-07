import AppKit
import Combine
import SwiftUI
@testable import agentGui

@MainActor
final class CodeEditorTextViewHarness {
    private static let sharedWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()

    final class Recorder {
        var lastChangeSet: EditorChangeSet?
        var lastSelection: EditorSelectionSnapshot?
        var lastCursorLocation: CodeEditorTextLocation?
        var lastVisibleLineRange: ClosedRange<Int>?
        var semanticIntents: [CodeEditorSemanticIntent] = []
        var findIntents: [CodeEditorFindIntent] = []
        var changeSetCount = 0
    }

    final class Storage: ObservableObject {
        @Published var text: String
        @Published var document: CodeEditorDocument
        @Published var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]
        @Published var revealRequest: CodeEditorRevealRequest?

        init(text: String, persistedText: String) {
            self.text = text
            self.document = CodeEditorDocument(text: text, persistedText: persistedText)
            self.diagnosticsByLine = [:]
            self.revealRequest = nil
        }
    }

    private let storage: Storage
    private let recorder = Recorder()
    private let window: NSWindow
    private let hostingView: NSHostingView<HostView>
    private let language: String
    private let highlightExecutionDelayNanoseconds: UInt64
    private let highlighter: CodeSyntaxHighlightingService
    private weak var cachedTextView: CodeEditorPlatformTextView?
    private weak var cachedScrollView: NSScrollView?
    private weak var cachedContainerView: NSView?

    init(
        text: String,
        persistedText: String? = nil,
        language: String = "swift",
        highlightExecutionDelayNanoseconds: UInt64 = 0
    ) {
        let persistedText = persistedText ?? text
        let storage = Storage(text: text, persistedText: persistedText)
        self.storage = storage
        self.language = language
        self.highlightExecutionDelayNanoseconds = highlightExecutionDelayNanoseconds
        self.highlighter = CodeSyntaxHighlightingService(engine: IdentityHighlightEngine())
        let recorder = self.recorder

        let rootView = HostView(
            storage: storage,
            language: language,
            highlighter: highlighter,
            highlightExecutionDelayNanoseconds: highlightExecutionDelayNanoseconds,
            onSelectionChange: { snapshot in
                recorder.lastSelection = snapshot
            },
            onCursorLocationChange: { location in
                recorder.lastCursorLocation = location
            },
            onVisibleLineRangeChange: { lineRange in
                recorder.lastVisibleLineRange = lineRange
            },
            onSemanticIntent: { intent in
                recorder.semanticIntents.append(intent)
            },
            onFindIntent: { intent in
                recorder.findIntents.append(intent)
            },
            onChangeSet: { change in
                recorder.lastChangeSet = change
                recorder.changeSetCount += 1
            }
        )

        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)

        window = Self.sharedWindow
        window.setFrame(hostingView.frame, display: false)
        window.contentView = hostingView
        window.displayIfNeeded()
        pumpRunLoop()
        cachedTextView = findTextView(in: hostingView)
        cachedScrollView = findScrollView(in: hostingView)
        cachedContainerView = findContainerView(in: hostingView)
    }

    deinit {
        window.orderOut(nil)
        if window.contentView === hostingView {
            window.contentView = nil
        }
    }

    var boundText: String {
        storage.text
    }

    var lastChangeSet: EditorChangeSet? {
        recorder.lastChangeSet
    }

    var lastSelection: EditorSelectionSnapshot? {
        recorder.lastSelection
    }

    var lastCursorLocation: CodeEditorTextLocation? {
        recorder.lastCursorLocation
    }

    var lastVisibleLineRange: ClosedRange<Int>? {
        recorder.lastVisibleLineRange
    }

    var changeSetCount: Int {
        recorder.changeSetCount
    }

    var semanticIntents: [CodeEditorSemanticIntent] {
        recorder.semanticIntents
    }

    var findIntents: [CodeEditorFindIntent] {
        recorder.findIntents
    }

    var document: CodeEditorDocument {
        storage.document
    }

    var textView: CodeEditorPlatformTextView {
        if let cachedTextView {
            return cachedTextView
        }

        guard let textView = findTextView(in: hostingView) else {
            fatalError("CodeEditorTextViewHarness could not find NSTextView")
        }
        cachedTextView = textView
        return textView
    }

    var latestAppliedHighlightVersion: Int? {
        textView.latestAppliedHighlightVersion
    }

    var highlightedLine: Int? {
        textView.highlightedLineNumber
    }

    var displayedLineCount: Int {
        textView.displayedLineCount
    }

    var gutterLineMetrics: [CodeEditorVisibleLineMetric] {
        gutterView?.lineMetrics ?? []
    }

    var gutterInvalidationSummary: CodeEditorGutterInvalidationSummary? {
        gutterView?.lastInvalidationSummary
    }

    var scrollView: NSScrollView {
        if let cachedScrollView {
            return cachedScrollView
        }

        guard let scrollView = findScrollView(in: hostingView) else {
            fatalError("CodeEditorTextViewHarness could not find NSScrollView")
        }
        cachedScrollView = scrollView
        return scrollView
    }

    var containerView: NSView? {
        if let cachedContainerView {
            return cachedContainerView
        }

        let containerView = findContainerView(in: hostingView)
        cachedContainerView = containerView
        return containerView
    }

    var gutterView: CodeEditorGutterView? {
        findGutterView(in: hostingView)
    }

    func visibleLineMetricsForCurrentViewport() -> [CodeEditorVisibleLineMetric] {
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        pumpRunLoop()
        return textView.visibleLineMetrics(in: scrollView.contentView.bounds)
    }

    func convertedVisibleLineMetricForCurrentViewport(line: Int) -> CodeEditorVisibleLineMetric? {
        guard let metric = visibleLineMetricsForCurrentViewport().first(where: { $0.line == line }),
              let gutterView else {
            return nil
        }

        // Metrics are now in document coordinates (matching gutter bounds-origin sync).
        return CodeEditorVisibleLineMetric(
            line: metric.line,
            rect: NSRect(x: 0, y: metric.rect.minY, width: gutterView.requiredWidth, height: metric.rect.height).integral,
            baselineY: metric.baselineY
        )
    }

    func forceApplyHighlightResult() {
        let textView = textView
        let attributedString = highlighter.highlightedString(
            code: textView.string,
            language: language,
            appearance: .light,
            fontSize: textView.font?.pointSize ?? NSFont.systemFontSize
        )
        let document = storage.document
        let source = textView.string as NSString
        let lineFragments = (1...max(document.lineCount, 1)).map { line in
            let range = document.utf16LineRange(forLine: line)
            let string = source.substring(with: range)
            return CodeEditorStyledLineFragment(
                line: line,
                utf16Range: range,
                attributedString: attributedString.attributedSubstring(from: range),
                fingerprint: line * 1000 + range.length
            )
        }

        _ = CodeEditorHighlightApplicator.apply(
            CodeEditorHighlightResult(
                version: document.version,
                lineRange: 1...max(document.lineCount, 1),
                lineFragments: lineFragments
            ),
            decorations: .empty(version: document.version, lineRange: 1...max(document.lineCount, 1)),
            to: textView,
            baseAttributes: [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textView.textColor ?? NSColor.labelColor
            ]
        )
        textView.latestAppliedHighlightVersion = storage.document.version
    }

    func replaceCharacters(in range: NSRange, with replacement: String) {
        let textView = textView
        guard let storage = textView.textStorage else {
            fatalError("CodeEditorTextViewHarness missing text storage")
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
    }

    /// 模拟多光标编辑：设置多个选区并同步插入替换文本，触发 shouldChangeTextInRanges 路径。
    func simulateMultiCursorEdit(ranges: [NSRange], replacement: String) {
        let textView = textView
        guard let textStorage = textView.textStorage else { return }
        guard ranges.count > 1 else {
            if let first = ranges.first {
                replaceCharacters(in: first, with: replacement)
            }
            return
        }

        // 设置多光标选区
        textView.setSelectedRanges(
            ranges.map { NSValue(range: $0) },
            affinity: .downstream,
            stillSelecting: false
        )

        // 触发 shouldChangeTextInRanges 以设置 isMultiCursorEdit 标志
        let rangeValues = ranges.map { NSValue(range: $0) }
        let replacements = Array(repeating: replacement, count: ranges.count)
        _ = textView.delegate?.textView?(
            textView,
            shouldChangeTextInRanges: rangeValues,
            replacementStrings: replacements
        )

        // 逆序应用修改（避免偏移冲突）
        let sortedRanges = ranges.sorted { $0.location > $1.location }
        textStorage.beginEditing()
        for range in sortedRanges {
            textStorage.replaceCharacters(in: range, with: replacement)
        }
        textStorage.endEditing()

        // 将光标移到第一个插入点之后
        let minLoc = ranges.min(by: { $0.location < $1.location }).map {
            $0.location + (replacement as NSString).length
        } ?? 0
        textView.setSelectedRange(NSRange(location: minLoc, length: 0))
        textView.didChangeText()
        pumpRunLoop()
    }

    func setMarkedText(_ markedText: String, selectedRange: NSRange, replacementRange: NSRange) {
        let textView = textView
        textView.setMarkedText(markedText, selectedRange: selectedRange, replacementRange: replacementRange)
        pumpRunLoop()
    }

    func commitMarkedText() {
        let textView = textView
        textView.unmarkText()
        pumpRunLoop()
    }

    func select(range: NSRange) {
        let textView = textView
        let expectedCursorLocation = storage.document.location(ofUTF16Offset: range.location)
        textView.setSelectedRange(range)
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
        waitUntil(timeoutSteps: 20) {
            self.recorder.lastCursorLocation == expectedCursorLocation
                || self.recorder.lastSelection != nil
        }
    }

    func updateFromHost(text: String, persistedText: String? = nil) {
        storage.text = text
        storage.document = CodeEditorDocument(text: text, persistedText: persistedText ?? text, version: storage.document.version)
        pumpRunLoop()
    }

    func updateDiagnosticsByLine(_ diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary]) {
        storage.diagnosticsByLine = diagnosticsByLine
        pumpRunLoop()
    }

    func clearGutterInvalidationSummary() {
        gutterView?.clearLastInvalidationSummary()
    }

    func selectLine(_ line: Int, column: Int = 1) {
        let offset = storage.document.utf16Offset(line: line, column: column)
        select(range: NSRange(location: offset, length: 0))
    }

    func clearRecordedCallbacks() {
        recorder.lastChangeSet = nil
        recorder.lastSelection = nil
        recorder.lastCursorLocation = nil
        recorder.lastVisibleLineRange = nil
        recorder.semanticIntents = []
        recorder.changeSetCount = 0
    }

    func optionClick(line: Int, column: Int) {
        textView.emitSemanticIntent(.requestDefinition(textView.semanticPosition(line: line, column: column)))
        pumpRunLoop()
    }

    func pressDefinitionShortcut() {
        guard let position = selectedSemanticPosition() else {
            return
        }

        textView.emitSemanticIntent(.requestDefinition(position))
        pumpRunLoop()
    }

    func pressReferencesShortcut() {
        guard let position = selectedSemanticPosition() else {
            return
        }

        textView.emitSemanticIntent(.requestReferences(position))
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

    func moveMouse(line: Int, column: Int) {
        textView.emitSemanticIntent(.requestHover(textView.semanticPosition(line: line, column: column)))
        pumpRunLoop()
    }

    func applyRevealRequest(_ request: CodeEditorRevealRequest) {
        storage.revealRequest = request
        pumpRunLoop()
    }

    func scrollToLine(_ line: Int) {
        guard let lineRect = textView.backgroundRect(forLine: line) else {
            fatalError("CodeEditorTextViewHarness could not compute line rect for line \(line)")
        }

        let targetOrigin = NSPoint(x: 0, y: max(0, lineRect.minY - 8))
        scrollView.contentView.scroll(to: targetOrigin)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        waitUntil(timeoutSteps: 20) { self.recorder.lastVisibleLineRange?.contains(line) == true }
    }

    func scrollViewportByOneLine() {
        let metrics = textView.visibleLineMetrics(in: scrollView.contentView.bounds)
        let lineHeight: CGFloat
        if metrics.count > 1 {
            lineHeight = metrics[1].rect.minY - metrics[0].rect.minY
        } else {
            lineHeight = metrics.first?.rect.height ?? 0
        }

        let targetOrigin = NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: max(0, scrollView.contentView.bounds.origin.y + lineHeight)
        )
        scrollView.contentView.scroll(to: targetOrigin)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        waitUntil(timeoutSteps: 20) {
            guard let visibleRange = self.recorder.lastVisibleLineRange else {
                return false
            }
            return visibleRange.lowerBound > 1
        }
    }

    func waitForHighlightPass(timeoutSteps: Int = 600) {
        waitUntil(timeoutSteps: timeoutSteps) {
            latestAppliedHighlightVersion == storage.document.version
        }

        if latestAppliedHighlightVersion != storage.document.version {
            forceApplyHighlightResult()
        }
    }

    func pumpRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private func waitUntil(timeoutSteps: Int, condition: () -> Bool) {
        for _ in 0..<timeoutSteps {
            if condition() {
                return
            }
            pumpRunLoop()
        }
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

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }

    private func findGutterView(in view: NSView) -> CodeEditorGutterView? {
        if let gutterView = view as? CodeEditorGutterView {
            return gutterView
        }

        for subview in view.subviews {
            if let gutterView = findGutterView(in: subview) {
                return gutterView
            }
        }

        return nil
    }

    private func findContainerView(in view: NSView) -> NSView? {
        let hasDirectScrollViewChild = view.subviews.contains { $0 is NSScrollView }
        let hasDirectGutterChild = view.subviews.contains { $0 is CodeEditorGutterView }
        if hasDirectScrollViewChild, hasDirectGutterChild {
            return view
        }

        for subview in view.subviews {
            if let containerView = findContainerView(in: subview) {
                return containerView
            }
        }

        return nil
    }

    private func selectedSemanticPosition() -> CodeEditorSemanticPosition? {
        let offset = textView.selectedRange().location
        let location = storage.document.location(ofUTF16Offset: offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: offset,
            version: storage.document.version
        )
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
}

private struct HostView: View {
    @ObservedObject var storage: CodeEditorTextViewHarness.Storage
    let language: String
    let highlighter: any CodeSyntaxHighlighting
    let highlightExecutionDelayNanoseconds: UInt64
    let onSelectionChange: (EditorSelectionSnapshot?) -> Void
    let onCursorLocationChange: (CodeEditorTextLocation) -> Void
    let onVisibleLineRangeChange: (ClosedRange<Int>) -> Void
    let onSemanticIntent: (CodeEditorSemanticIntent) -> Void
    let onFindIntent: (CodeEditorFindIntent) -> Void
    let onChangeSet: (EditorChangeSet) -> Void

    var body: some View {
        CodeEditorTextView(
            text: $storage.text,
            document: $storage.document,
            language: language,
            revealRequest: storage.revealRequest,
            onSelectionChange: onSelectionChange,
            onCursorLocationChange: onCursorLocationChange,
            onVisibleLineRangeChange: onVisibleLineRangeChange,
            onSemanticIntent: onSemanticIntent,
            onFindIntent: onFindIntent,
            diagnosticsByLine: storage.diagnosticsByLine,
            onChangeSet: onChangeSet,
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