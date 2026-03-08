//
//  BlockTextEditor.swift
//  agentGui
//

import AppKit
import SwiftUI

enum BlockEditorCommand {
    case split(selectedRange: NSRange)
    case mergeBackward(selectedRange: NSRange)
    case indent
    case outdent
    case moveFocusUp
    case moveFocusDown
    case slashMoveUp
    case slashMoveDown
    case slashCommit
    case slashDismiss
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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
        applyStyle(to: textView)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? BlockEditorTextView else { return }
        textView.isEditable = isEditable
        textView.placeholder = placeholder
        textView.blockKind = kind
        textView.onFileDropped = onFileDrop
        textView.onCommand = onCommand
        textView.onFocusChange = onFocusChange
        applyStyle(to: textView)
        if textView.string != text {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
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
        context.coordinator.recalculateHeight(textView)
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

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let baseFont = font(for: kind)
        let base = baseAttributes(for: kind)
        let markerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
        let accentColor = NSColor.controlAccentColor

        textStorage.beginEditing()
        textStorage.setAttributes(base, range: fullRange)

        applyMarkdownPattern(#"(\*\*)(.+?)(\*\*)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([.font: boldFont(from: baseFont)], range: inner)
        }

        applyMarkdownPattern(#"(__)(.+?)(__)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([.font: boldFont(from: baseFont)], range: inner)
        }

        applyMarkdownPattern(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([.font: italicFont(from: baseFont)], range: inner)
        }

        applyMarkdownPattern(#"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([.font: italicFont(from: baseFont)], range: inner)
        }

        applyMarkdownPattern(#"(`)(.+?)(`)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: max(baseFont.pointSize - 1, 12), weight: .regular),
                .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.9)
            ], range: inner)
        }

        applyMarkdownPattern(#"(~~)(.+?)(~~)"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: inner)
        }

        applyMarkdownPattern(#"(\[)(.+?)(\]\((.+?)\))"#, in: textStorage, baseFont: baseFont) { whole, inner in
            textStorage.addAttributes([.foregroundColor: markerColor], range: whole)
            textStorage.addAttributes([
                .foregroundColor: accentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: inner)
        }

        textStorage.endEditing()
    }

    private func applyMarkdownPattern(_ pattern: String, in textStorage: NSTextStorage, baseFont: NSFont, handler: (NSRange, NSRange) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let matches = regex.matches(in: textStorage.string, options: [], range: fullRange)
        for match in matches {
            let whole = match.range(at: 0)
            let primaryInner = match.range(at: 2)
            let fallbackInner = match.range(at: 1)
            let inner = primaryInner.location != NSNotFound ? primaryInner : fallbackInner
            guard inner.location != NSNotFound else { continue }
            handler(whole, inner)
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

        init(_ parent: BlockTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? BlockEditorTextView else { return }
            parent.text = textView.string
            parent.applyStyle(to: textView)
            parent.onTextChange(textView.string)
            recalculateHeight(textView)
            textView.needsDisplay = true
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

          fileprivate func recalculateHeight(_ textView: BlockEditorTextView) {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let minimumHeight: CGFloat = textView.blockKind.isHeading ? 24 : 28
            let height = max(minimumHeight, ceil(usedRect.height + textView.textContainerInset.height * 2 + 4))
            if let scrollView = textView.enclosingScrollView, abs(scrollView.frame.height - height) > 1 {
                scrollView.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }
                scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
            }
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
        isSlashCommandContext && [53, 125, 126, 36, 76].contains(Int(event.keyCode))
    }

    private func shouldIndent(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && supportsIndentation
    }

    private func shouldMoveFocusUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 126 else { return false }
        let range = selectedRange()
        return range.length == 0 && range.location == 0 && !isSlashCommandContext
    }

    private func shouldMoveFocusDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == 125 else { return false }
        let range = selectedRange()
        return range.length == 0 && range.location == string.utf16.count && !isSlashCommandContext
    }

    private func handleSlashCommandKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53:
            onCommand?(.slashDismiss)
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

    private var isSlashCommandContext: Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
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
}

private extension DocumentBlockKind {
    var isHeading: Bool {
        self == .heading1 || self == .heading2 || self == .heading3
    }
}
