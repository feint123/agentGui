import AppKit
import SwiftUI

// MARK: - Indent Guide Config

/// 缩进参考线所需配置，从 CodeEditorIndentationStatus 派生。
struct CodeEditorIndentGuideConfig: Equatable, Sendable {
    let indentWidth: Int   // 每级缩进的字符数，<=0 时禁用
    let useTabs: Bool

    static let disabled = CodeEditorIndentGuideConfig(indentWidth: 0, useTabs: false)

    init(indentWidth: Int, useTabs: Bool) {
        self.indentWidth = indentWidth
        self.useTabs = useTabs
    }

    init(from status: CodeEditorIndentationStatus) {
        switch status.kind {
        case .spaces:
            self.init(indentWidth: max(1, status.width), useTabs: false)
        case .tabs:
            self.init(indentWidth: max(1, status.width), useTabs: true)
        case .unknown:
            self.init(indentWidth: 4, useTabs: false) // 默认 4 spaces
        }
    }
}

// MARK: - Platform Text View

final class CodeEditorPlatformTextView: NSTextView {
    var latestAppliedHighlightVersion: Int?
    var latestHighlightResult: CodeEditorHighlightResult?

    // MARK: - Indent Guides

    /// 缩进参考线配置，由 Coordinator 在 updateNSView 时写入。
    /// indentWidth <= 0 时不绘制参考线。
    var indentGuideConfig: CodeEditorIndentGuideConfig = .disabled {
        didSet {
            guard indentGuideConfig != oldValue else { return }
            setNeedsDisplay(visibleRect)
        }
    }

    // MARK: - Bracket Match Highlight
    /// 当前已应用的括号高亮范围（用于后续清除）
    var appliedBracketMatchRanges: (open: NSRange, close: NSRange)?

    /// 括号高亮背景色
    static let bracketMatchBackgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
    var latestDecorationSnapshot: CodeEditorDecorationSnapshot = .empty(version: 0, lineRange: 1...1)
    var currentDocumentVersion: Int = 0
    var compositionStateChangeHandler: ((CodeEditorPlatformTextView) -> Void)?
    var semanticIntentHandler: ((CodeEditorSemanticIntent) -> Void)?
    var findIntentHandler: ((CodeEditorFindIntent) -> Void)?

    // MARK: - Completion
    /// 键盘操作代理（Coordinator 实现），当面板可见时拦截 Tab/Enter/Esc/↑↓ 键。
    weak var completionDelegate: (any CompletionKeyDelegate)?

    // MARK: - Signature Help
    /// 签名帮助键盘代理（Coordinator 实现）
    weak var signatureHelpDelegate: (any SignatureHelpKeyDelegate)?

    // MARK: - Agent Change Diff（F24 Inline Background）

    /// Agent 修改的行级 diff，由 Coordinator 更新，drawBackground 消费。
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:] {
        didSet {
            guard agentChangeDiffByLine != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - Inlay Hints

    /// 当前 viewport 的 inlay hints 快照。
    /// 由 Coordinator 在主线程写入，drawBackground 消费。
    var currentInlayHintSnapshot: CodeEditorInlayHintSnapshot = .empty {
        didSet {
            guard currentInlayHintSnapshot.documentVersion != oldValue.documentVersion
                || currentInlayHintSnapshot.hintsByLine != oldValue.hintsByLine
            else { return }
            setNeedsDisplay(visibleRect)
        }
    }

    // MARK: - Ghost Text

    /// 当前 AI ghost text 建议快照（nil = 无建议）。
    /// 由 Coordinator 在主线程写入，drawBackground 消费（不修改 NSTextStorage）。
    var currentGhostText: CodeEditorGhostTextSnapshot? {
        didSet {
            guard currentGhostText?.generation != oldValue?.generation
                || currentGhostText?.text != oldValue?.text
            else { return }
            needsDisplay = true
        }
    }

    /// accept 操作进行中时设为 true，防止 setSelectedRanges 重写误清除 ghost text。
    var isAcceptingGhostText = false

    var appliedLinePresentationFingerprints: [Int: Int] = [:]
    var lastReappliedLines: [Int] = []
    var highlightedLineNumbers: Set<Int> = [] {
        didSet {
            guard highlightedLineNumbers != oldValue else { return }
            for line in oldValue { invalidateLine(line) }
            for line in highlightedLineNumbers { invalidateLine(line) }
        }
    }

    /// 向后兼容：单光标读写单个行
    var highlightedLineNumber: Int? {
        get { highlightedLineNumbers.first }
        set {
            if let n = newValue {
                highlightedLineNumbers = [n]
            } else {
                highlightedLineNumbers = []
            }
        }
    }
    var displayedLineIndex = CodeEditorLineIndex(text: "")
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

    // MARK: - Displayed State

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

    // MARK: - Semantic Intent

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

    func codePosition(for utf16Offset: Int) -> (line: Int, character: Int) {
        let location = displayedLineIndex.location(ofUTF16Offset: utf16Offset)
        return (
            line: max(0, location.line - 1),
            character: max(0, location.column - 1)
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

    // MARK: - Ghost Text State

    /// 光标偏离失效（对齐 Zed update_visible_edit_prediction invalidation_range）。
    /// 若光标移动到不同于 insertionOffset 的位置，自动清除 ghost text。
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !isAcceptingGhostText else { return }
        if let snap = currentGhostText {
            let cursor = selectedRange().location
            if cursor != snap.insertionOffset {
                currentGhostText = nil
            }
        }
    }

    func clearGhostText() {
        currentGhostText = nil
    }

    /// 提取 ghost text 请求所需的前缀/后缀上下文（各最多 200/20 行）
    func extractGhostTextContext(language: String? = nil) -> (prefix: String, suffix: String, language: String)? {
        guard let storage = textStorage else { return nil }
        let fullText = storage.string
        let cursorPos = selectedRange().location
        guard cursorPos <= fullText.utf16.count else { return nil }

        let utf16 = fullText.utf16
        guard cursorPos <= utf16.count else { return nil }
        let prefixEndIdx = utf16.index(utf16.startIndex, offsetBy: cursorPos)

        let prefixUTF16 = String(utf16[utf16.startIndex..<prefixEndIdx]) ?? ""
        let suffixUTF16 = String(utf16[prefixEndIdx...]) ?? ""

        let prefixLines = prefixUTF16.components(separatedBy: "\n")
        let suffixLines = suffixUTF16.components(separatedBy: "\n")

        let prefix = prefixLines.suffix(200).joined(separator: "\n")
        let suffix = suffixLines.prefix(20).joined(separator: "\n")

        return (prefix: prefix, suffix: suffix, language: language ?? "swift")
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

    func clampRange(_ range: NSRange, max length: Int) -> NSRange {
        let location = Swift.max(0, Swift.min(range.location, length))
        let safeLength = Swift.max(0, Swift.min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }

    // MARK: - Private Helpers

    func displayedUTF16LineRange(forLine line: Int) -> NSRange {
        let safeLine = max(1, min(line, displayedLineIndex.lineCount))
        let startOffset = displayedLineIndex.lineStartOffset(forLine: safeLine)
        let endOffset = safeLine < displayedLineIndex.lineCount
            ? displayedLineIndex.lineStartOffset(forLine: safeLine + 1)
            : (string as NSString).length

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    func displayedVisibleLineRange(
        in visibleRect: NSRect,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> ClosedRange<Int>? {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lineRange = displayedLineRange(for: characterRange)
        return lineRange.startLine...max(lineRange.endLine, lineRange.startLine)
    }

    func displayedLineRect(
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

    func invalidateLine(_ line: Int?) {
        guard let line,
              let rect = backgroundRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }

    func semanticPosition(at point: NSPoint) -> CodeEditorSemanticPosition? {
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

    func semanticPositionForSelection() -> CodeEditorSemanticPosition? {
        let offset = max(0, min(selectedRange().location, (string as NSString).length))
        let location = displayedLineIndex.location(ofUTF16Offset: offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: offset,
            version: currentDocumentVersion
        )
    }

    func hoverAnchorRect(forUTF16Offset offset: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let safeOffset = max(0, min(offset, (string as NSString).length))
        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: safeOffset),
            max(layoutManager.numberOfGlyphs - 1, 0)
        )
        let lineFragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        guard !lineFragRect.isEmpty else { return nil }

        let origin = textContainerOrigin
        return NSRect(
            x: origin.x + glyphLocation.x,
            y: origin.y + lineFragRect.minY,
            width: max(1, font?.maximumAdvancement.width ?? NSFont.systemFontSize * 0.6),
            height: lineFragRect.height
        ).integral
    }
}

// MARK: - Completion Helpers

extension CodeEditorPlatformTextView {
    /// 光标前的当前词（word boundary: alphanumeric + underscore + non-ASCII）。
    func prefixWordBeforeCursor(maxLength: Int = 200) -> String {
        let offset = selectedRange().location
        let utf16 = string.utf16
        guard offset > 0, offset <= utf16.count else { return "" }
        var start = offset
        while start > 0 {
            let idx = utf16.index(utf16.startIndex, offsetBy: start - 1)
            let char = utf16[idx]
            // word character: alphanumeric, _, or non-ASCII
            let isWord = char == UInt16(0x5F) /* _ */
                || (char >= 0x30 && char <= 0x39)   // 0-9
                || (char >= 0x41 && char <= 0x5A)   // A-Z
                || (char >= 0x61 && char <= 0x7A)   // a-z
                || char > 0x7F                       // non-ASCII (Unicode identifiers)
            guard isWord else { break }
            start -= 1
            if offset - start > maxLength { break }
        }
        let startIdx = utf16.index(utf16.startIndex, offsetBy: start)
        let endIdx = utf16.index(utf16.startIndex, offsetBy: offset)
        return String(utf16[startIdx..<endIdx]) ?? ""
    }

    /// 光标左侧的上一个字符（用于 trigger character 检测）。
    var lastTypedCharacter: String? {
        let offset = selectedRange().location
        guard offset > 0 else { return nil }
        let utf16 = string.utf16
        guard offset <= utf16.count else { return nil }
        let idx = utf16.index(utf16.startIndex, offsetBy: offset - 1)
        return String(utf16[idx])
    }

    /// 当前光标在本视图坐标系的矩形（用于补全面板定位）。
    var cursorRect: NSRect {
        let offset = selectedRange().location
        guard let manager = layoutManager,
              let container = textContainer else { return .zero }
        let glyphIndex = min(manager.glyphIndexForCharacter(at: offset),
                             max(manager.numberOfGlyphs - 1, 0))
        let lineFragRect = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = manager.location(forGlyphAt: glyphIndex)
        return NSRect(
            x: textContainerOrigin.x + glyphLocation.x,
            y: textContainerOrigin.y + lineFragRect.minY,
            width: 2,
            height: lineFragRect.height
        )
    }
}
