//
//  BlockTextEditor.swift
//  agentGui
//

import AppKit
import SwiftUI
import OSLog

// MARK: - Performance Monitor

private let perfTextEditor = PerformanceMonitor.self

struct EditorInlineMarkdownMatch: Equatable {
    let fullRange: NSRange
    let contentRange: NSRange
    let markerRanges: [NSRange]
}

struct EditorInlineMarkdownRule {
    let regex: NSRegularExpression
    let contentCaptureIndex: Int
    let markerCaptureIndexes: [Int]

    func matches(in text: String) -> [EditorInlineMarkdownMatch] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: fullRange).compactMap { match in
            let contentRange = match.range(at: contentCaptureIndex)
            guard contentRange.location != NSNotFound else { return nil }
            let markerRanges = markerCaptureIndexes.compactMap { index -> NSRange? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : range
            }
            return EditorInlineMarkdownMatch(
                fullRange: match.range(at: 0),
                contentRange: contentRange,
                markerRanges: markerRanges
            )
        }
    }

    static let bold = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(\*\*)(.+?)(\*\*)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let boldUnderscore = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(__)(.+?)(__)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let italic = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(?<!\*)(\*)(?!\*)(.+?)(?<!\*)(\*)(?!\*)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let italicUnderscore = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(?<!_)(_)(?!_)(.+?)(?<!_)(_)(?!_)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let code = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(`)(.+?)(`)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let strikethrough = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(~~)(.+?)(~~)"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )

    static let link = EditorInlineMarkdownRule(
        regex: try! NSRegularExpression(pattern: #"(\[)(.+?)(\]\((.+?)\))"#, options: []),
        contentCaptureIndex: 2,
        markerCaptureIndexes: [1, 3]
    )
}

enum BlockEditorCommand {
    case split(selectedRange: NSRange)
    case mergeBackward(selectedRange: NSRange)
    case indent
    case outdent
    case moveFocusUp
    case moveFocusDown
    case slashMoveUp
    case slashMoveDown
    case slashMoveLeft
    case slashMoveRight
    case slashCommit
    case slashDismiss
    case dismissFloatingOverlays
}

struct BlockTextEditor: NSViewRepresentable {
    let blockID: UUID
    @Binding var text: String
    var placeholder: String
    var kind: DocumentBlockKind
    var focusRequest: BlockEditorFocusRequest?
    var isEditable: Bool = true
    var onTextChange: (String) -> Void = { _ in }
    var onCommand: (BlockEditorCommand) -> Void = { _ in }
    var onFileDrop: ([URL]) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSelectionChange: ((InlineSelectionState) -> Void)? = nil
    var onSlashChange: ((BlockEditorSlashContext?) -> Void)? = nil
    var pendingFormatRequest: InlineFormatRequest? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = BlockEditorTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.placeholder = placeholder
        textView.blockKind = kind
        textView.onFileDropped = onFileDrop
        textView.onCommand = onCommand
        textView.onFocusChange = onFocusChange
        textView.setAccessibilityIdentifier("blockEditor.textView")
        applyStyle(to: textView)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        // Add observer for frame changes to handle window resize
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            guard let coordinator = coordinator,
                  let tv = scrollView.documentView as? BlockEditorTextView else { return }
            // 宽度变化时强制重新计算（绕过缓存）
            coordinator.forceRecalculateHeight(tv)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BlockEditorTextView else { return }
        context.coordinator.parent = self

        // 优化：只在属性实际变化时才设置
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }

        // 优化：只在 kind 变化时重新应用样式
        let kindChanged = textView.blockKind != kind
        if kindChanged {
            textView.blockKind = kind
        }

        textView.onFileDropped = onFileDrop
        textView.onCommand = onCommand
        textView.onFocusChange = onFocusChange
        context.coordinator.parent.onSlashChange = onSlashChange

        // 只在 kind 变化或文本变化时应用样式
        if kindChanged || textView.string != text {
            applyStyle(to: textView)
        }

        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
            // 文本变化后需要重新计算高度
            context.coordinator.recalculateHeight(textView)
        }
        if let focusRequest, focusRequest.blockID == blockID, textView.lastAppliedFocusToken != focusRequest.token {
            textView.lastAppliedFocusToken = focusRequest.token
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
                let location = focusRequest.position == .end ? textView.string.utf16.count : 0
                textView.setSelectedRange(NSRange(location: location, length: 0))
                textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            }
        }

        // 优化：移除异步的 recalculateHeight 调用
        // 滚动时的视图复用不需要重新计算高度，缓存机制已经处理了这种情况

        // Defer format application to the next run-loop turn so it runs *outside* the
        // current SwiftUI render pass. Applying text changes inside updateNSView causes the
        // next updateNSView call (triggered by the binding update) to see a stale `text`
        // value and incorrectly reset textView.string back to the pre-format content.
        if let request = pendingFormatRequest,
           request.token != context.coordinator.lastAppliedFormatToken {
            let coordinator = context.coordinator
            let action = request.action
            coordinator.lastAppliedFormatToken = request.token
            DispatchQueue.main.async {
                guard let tv = scrollView.documentView as? BlockEditorTextView else { return }
                coordinator.applyFormat(action, to: tv)
            }
        }

        context.coordinator.publishSlashContext(for: textView)
    }

    private func applyStyle(to textView: BlockEditorTextView) {
        textView.font = font(for: kind)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = baseAttributes(for: kind)
        applyInlineMarkdownStyling(to: textView)
    }

    private func baseAttributes(for kind: DocumentBlockKind) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing(for: kind)
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        return [
            .font: font(for: kind),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func font(for kind: DocumentBlockKind) -> NSFont {
        switch kind {
        case .heading1:
            return .systemFont(ofSize: 26, weight: .bold)
        case .heading2:
            return .systemFont(ofSize: 20, weight: .semibold)
        case .heading3:
            return .systemFont(ofSize: 16, weight: .semibold)
        case .code, .source, .table:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        default:
            return .systemFont(ofSize: 14, weight: .regular)
        }
    }

    private func lineSpacing(for kind: DocumentBlockKind) -> CGFloat {
        switch kind {
        case .heading1: return 0
        case .heading2: return 0.5
        case .heading3: return 0.5
        case .code, .source, .table: return 1
        default: return 2
        }
    }

    private func applyInlineMarkdownStyling(to textView: BlockEditorTextView) {
        guard !kind.prefersMonospace,
              let textStorage = textView.textStorage else { return }

        // 性能监控：markdown 样式应用（仅在文本较长时监控）
        #if DEBUG
        if textStorage.length > 100 {
            let span = perfTextEditor.startSpan("BlockTextEditor.applyInlineStyling", category: "Editor", level: .verbose)
            defer {
                span.addMetadata("length", value: textStorage.length)
                span.addMetadata("kind", value: String(describing: kind))
                span.end()
            }
        }
        #endif

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let baseFont = font(for: kind)
        let base = baseAttributes(for: kind)
        let markerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
        let accentColor = NSColor.controlAccentColor

        textStorage.beginEditing()
        textStorage.setAttributes(base, range: fullRange)

        // 使用缓存的正则表达式，避免每次创建
        applyMarkdownRule(.bold, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([.font: boldFont(from: baseFont)], range: match.contentRange)
        }

        applyMarkdownRule(.boldUnderscore, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([.font: boldFont(from: baseFont)], range: match.contentRange)
        }

        applyMarkdownRule(.italic, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([.font: italicFont(from: baseFont)], range: match.contentRange)
        }

        applyMarkdownRule(.italicUnderscore, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([.font: italicFont(from: baseFont)], range: match.contentRange)
        }

        applyMarkdownRule(.code, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(baseFont.pointSize - 1, 12), weight: .regular),
                .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.9)
            ], range: match.contentRange)
        }

        applyMarkdownRule(.strikethrough, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: match.contentRange)
        }

        applyMarkdownRule(.link, in: textStorage) { match in
            colorMarkdownMarkers(match.markerRanges, in: textStorage, markerColor: markerColor)
            textStorage.addAttributes([
                .foregroundColor: accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.contentRange)
        }

        textStorage.endEditing()
    }

    private func applyMarkdownRule(_ rule: EditorInlineMarkdownRule, in textStorage: NSTextStorage, handler: (EditorInlineMarkdownMatch) -> Void) {
        for match in rule.matches(in: textStorage.string) {
            handler(match)
        }
    }

    private func colorMarkdownMarkers(_ markerRanges: [NSRange], in textStorage: NSTextStorage, markerColor: NSColor) {
        for range in markerRanges where range.location != NSNotFound {
            textStorage.addAttributes([.foregroundColor: markerColor], range: range)
        }
    }

    private func boldFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private func italicFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextEditor
        var lastAppliedFormatToken: UUID?

        // 高度计算缓存：避免重复计算
        private var lastCalculatedText: String = ""
        private var lastCalculatedHeight: CGFloat = 0

        /// The most recent non-empty selection range; persists after focus loss so
        /// toolbar button taps can still apply formatting to the right range.
        var savedSelectionRange: NSRange = NSRange(location: 0, length: 0)

        init(_ parent: BlockTextEditor) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? BlockEditorTextView else { return }
            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0 else {
                parent.onSelectionChange?(InlineSelectionState(
                    blockID: parent.blockID,
                    selectedRange: selectedRange,
                    selectionRect: .zero,
                    hasSelection: false,
                    activeActions: [],
                    selectedText: nil
                ))
                publishSlashContext(for: textView)
                return
            }
            savedSelectionRange = selectedRange
            var actualRange = NSRange()
            let screenRect = textView.firstRect(forCharacterRange: selectedRange, actualRange: &actualRange)
            let activeActions = detectActiveActions(in: textView, range: selectedRange)
            let selectedText = (textView.string as NSString).substring(with: selectedRange)
            parent.onSelectionChange?(InlineSelectionState(
                blockID: parent.blockID,
                selectedRange: selectedRange,
                selectionRect: screenRect,
                hasSelection: true,
                activeActions: activeActions,
                selectedText: selectedText
            ))
            publishSlashContext(for: textView)
        }

        private func detectActiveActions(in textView: NSTextView, range: NSRange) -> Set<InlineStyleAction> {
            var actions = Set<InlineStyleAction>()
            guard let storage = textView.textStorage else { return actions }
            storage.enumerateAttributes(in: range, options: []) { attrs, _, _ in
                if let font = attrs[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.boldFontMask) { actions.insert(.bold) }
                    if traits.contains(.italicFontMask) { actions.insert(.italic) }
                }
                if attrs[.strikethroughStyle] != nil { actions.insert(.strikethrough) }
                if attrs[.backgroundColor] != nil { actions.insert(.inlineCode) }
            }
            return actions
        }

        func applyFormat(_ action: InlineStyleAction, to textView: NSTextView) {
            // Use the saved range — reliable even after the text view loses first responder.
            let range = savedSelectionRange
            guard let storage = textView.textStorage,
                  range.length > 0,
                  range.location != NSNotFound,
                  NSMaxRange(range) <= storage.length
            else { return }
            let content = (storage.string as NSString).substring(with: range)
            let wrap = action.markdownWrap
            let replacement = "\(wrap)\(content)\(wrap)"
            // Use the lower-level API so the call is safe when the view is not first responder.
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: replacement)
            storage.endEditing()
            textView.didChangeText()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? BlockEditorTextView else { return }
            parent.text = textView.string
            parent.applyStyle(to: textView)
            parent.onTextChange(textView.string)
            recalculateHeight(textView)
            publishSlashContext(for: textView)
            textView.needsDisplay = true
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

          fileprivate func recalculateHeight(_ textView: BlockEditorTextView) {
            let currentText = textView.string

            // 优化：如果文本内容和上次相同，且高度已计算过，跳过
            if currentText == lastCalculatedText && lastCalculatedHeight > 0 {
                applyCachedHeight(textView, height: lastCalculatedHeight)
                return
            }

            // 性能监控：采样率 1%（只在 DEBUG 模式）
            #if DEBUG
            if Int.random(in: 0..<100) == 0 {
                let span = perfTextEditor.startSpan("BlockTextEditor.recalculateHeight", category: "Editor", level: .verbose)
                defer {
                    span.addMetadata("textLength", value: currentText.count)
                    span.addMetadata("kind", value: String(describing: textView.blockKind))
                    span.addMetadata("cached", value: currentText == lastCalculatedText)
                    span.end()
                }
            }
            #endif

            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let minimumHeight: CGFloat = textView.blockKind.isHeading ? 24 : 28
            let height = max(minimumHeight, ceil(usedRect.height + textView.textContainerInset.height * 2 + 4))

            // 更新缓存
            lastCalculatedText = currentText
            lastCalculatedHeight = height

            if let scrollView = textView.enclosingScrollView, abs(scrollView.frame.height - height) > 1 {
                scrollView.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
                scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
        }

        /// 应用缓存的高度（轻量级操作）
        private func applyCachedHeight(_ textView: BlockEditorTextView, height: CGFloat) {
            guard let scrollView = textView.enclosingScrollView,
                  abs(scrollView.frame.height - height) > 1 else { return }
            scrollView.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
            scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        }

        /// 强制重新计算高度（绕过缓存），用于宽度变化等场景
        fileprivate func forceRecalculateHeight(_ textView: BlockEditorTextView) {
            // 清除缓存，强制重新计算
            lastCalculatedText = ""
            lastCalculatedHeight = 0
            recalculateHeight(textView)
        }

        fileprivate func publishSlashContext(for textView: BlockEditorTextView) {
            guard let match = BlockEditorSlashQueryParser.detect(in: textView.string, selectedRange: textView.selectedRange()) else {
                parent.onSlashChange?(nil)
                return
            }

            parent.onSlashChange?(
                BlockEditorSlashContext(
                    blockID: parent.blockID,
                    currentKind: parent.kind,
                    match: match,
                    anchorRect: caretScreenRect(for: textView, selectedRange: textView.selectedRange(), match: match)
                )
            )
        }

        private func caretScreenRect(for textView: NSTextView, selectedRange: NSRange, match: BlockEditorSlashQueryParser.Match) -> CGRect {
            var actualRange = NSRange()
            let directRect = textView.firstRect(forCharacterRange: selectedRange, actualRange: &actualRange)
            if !directRect.isEmpty {
                return directRect
            }

            let anchorLocation = min(match.tokenRange.location + match.tokenRange.length, textView.string.utf16.count)
            let fallbackRange = NSRange(location: anchorLocation, length: 0)
            let fallbackRect = textView.firstRect(forCharacterRange: fallbackRange, actualRange: &actualRange)
            if !fallbackRect.isEmpty {
                return fallbackRect
            }

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let window = textView.window else {
                return .zero
            }

            let characterCount = textView.string.utf16.count
            let glyphCharacterIndex = max(min(anchorLocation - 1, characterCount - 1), 0)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: glyphCharacterIndex)
            var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            if anchorLocation == characterCount {
                rect.origin.x = rect.maxX
            }
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            let rectInWindow = textView.convert(rect, to: nil)
            return window.convertToScreen(rectInWindow)
        }
    }
}

private final class BlockEditorTextView: NSTextView {
    var placeholder = ""
    var blockKind: DocumentBlockKind = .paragraph
    var onCommand: ((BlockEditorCommand) -> Void)?
    var onFileDropped: (([URL]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var lastAppliedFocusToken: UUID?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let raw = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let urls = raw?.compactMap { ($0 as? NSURL) as URL? } ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        DispatchQueue.main.async { [weak self] in self?.onFileDropped?(urls) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !isComposingMarkedText else {
            super.keyDown(with: event)
            return
        }

        if shouldHandleSlashCommandKey(event) {
            handleSlashCommandKey(event)
            return
        }

        if shouldIndent(event) {
            onCommand?(event.modifierFlags.contains(.shift) ? .outdent : .indent)
            return
        }

        if shouldSplitOnReturn(event) {
            onCommand?(.split(selectedRange: selectedRange()))
            return
        }

        if shouldMergeBackward(event) {
            onCommand?(.mergeBackward(selectedRange: selectedRange()))
            return
        }

        if shouldMoveFocusUp(event) {
            onCommand?(.moveFocusUp)
            return
        }

        if shouldMoveFocusDown(event) {
            onCommand?(.moveFocusDown)
            return
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let rect = NSRect(x: textContainerInset.width + 2, y: textContainerInset.height + 1, width: bounds.width - 12, height: 22)
        placeholder.draw(in: rect, withAttributes: attributes)
    }

    private func shouldSplitOnReturn(_ event: NSEvent) -> Bool {
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        guard !event.modifierFlags.contains(.shift) else { return false }
        return !allowsMultilineReturn
    }

    private func shouldMergeBackward(_ event: NSEvent) -> Bool {
        guard event.keyCode == 51 else { return false }
        let range = selectedRange()
        return range.length == 0 && range.location == 0
    }

    private func shouldHandleSlashCommandKey(_ event: NSEvent) -> Bool {
        isSlashCommandContext(at: selectedRange()) && [53, 123, 124, 125, 126, 36, 76].contains(Int(event.keyCode))
    }

    private func shouldIndent(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && supportsIndentation
    }

    private func shouldMoveFocusUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 126 else { return false }
        let range = selectedRange()
        return range.length == 0 && range.location == 0 && !isSlashCommandContext(at: range)
    }

    private func shouldMoveFocusDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 125 else { return false }
        let range = selectedRange()
        return range.length == 0 && range.location == string.utf16.count && !isSlashCommandContext(at: range)
    }

    private func handleSlashCommandKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCommand?(.slashDismiss)
        case 123:
            onCommand?(.slashMoveLeft)
        case 124:
            onCommand?(.slashMoveRight)
        case 125:
            onCommand?(.slashMoveDown)
        case 126:
            onCommand?(.slashMoveUp)
        case 36, 76:
            onCommand?(.slashCommit)
        default:
            break
        }
    }

    private func isSlashCommandContext(at range: NSRange) -> Bool {
        BlockEditorSlashQueryParser.detect(in: string, selectedRange: range) != nil
    }

    private var isComposingMarkedText: Bool {
        hasMarkedText()
    }

    private var allowsMultilineReturn: Bool {
        blockKind == .code || blockKind == .source || blockKind == .table
    }

    private var supportsIndentation: Bool {
        blockKind == .bulletedList || blockKind == .numberedList || blockKind == .todo || blockKind == .quote
    }

    override func cancelOperation(_ sender: Any?) {
        if isSlashCommandContext(at: selectedRange()) {
            onCommand?(.slashDismiss)
            return
        }

        let range = selectedRange()
        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location, length: 0))
            onCommand?(.dismissFloatingOverlays)
            return
        }

        super.cancelOperation(sender)
    }
}

private extension DocumentBlockKind {
    var isHeading: Bool {
        self == .heading1 || self == .heading2 || self == .heading3
    }
}
