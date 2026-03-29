import AppKit

enum BlockInlineMarkdownStyler {
    static func font(for kind: DocumentBlockKind) -> NSFont {
        switch kind {
        case .heading1:
            return .systemFont(ofSize: 26, weight: .bold)
        case .heading2:
            return .systemFont(ofSize: 20, weight: .semibold)
        case .heading3:
            return .systemFont(ofSize: 16, weight: .semibold)
        case .code, .source:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        default:
            return .systemFont(ofSize: 14, weight: .regular)
        }
    }

    static func baseAttributes(for kind: DocumentBlockKind) -> [NSAttributedString.Key: Any] {
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

    static func markerRanges(in text: String) -> [NSRange] {
        BlockMarkdownCodec.inlineMarkerRanges(in: text)
    }

    static func apply(to textView: NSTextView, kind: DocumentBlockKind, renderKind: DocumentBlockKind? = nil, hideMarkdownMarkers: Bool = true) {
        apply(
            to: textView,
            kind: kind,
            renderKind: renderKind,
            hideMarkdownMarkers: hideMarkdownMarkers,
            language: nil,
            highlighter: CodeSyntaxHighlightingService.shared
        )
    }

    static func apply(
        to textView: NSTextView,
        kind: DocumentBlockKind,
        renderKind: DocumentBlockKind? = nil,
        hideMarkdownMarkers: Bool = true,
        language: String?
    ) {
        apply(
            to: textView,
            kind: kind,
            renderKind: renderKind,
            hideMarkdownMarkers: hideMarkdownMarkers,
            language: language,
            highlighter: CodeSyntaxHighlightingService.shared
        )
    }

    static func apply(
        to textView: NSTextView,
        kind: DocumentBlockKind,
        renderKind: DocumentBlockKind? = nil,
        hideMarkdownMarkers: Bool = true,
        language: String?,
        highlighter: any CodeSyntaxHighlighting
    ) {
        let styleKind = renderKind ?? kind
        let projection = BlockInlineMarkdownProjection(sourceText: textView.string)
        textView.font = font(for: styleKind)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = baseAttributes(for: styleKind)

        guard let textStorage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let baseFont = font(for: styleKind)
        let base = baseAttributes(for: styleKind)
        let accentColor = NSColor.controlAccentColor

        textStorage.beginEditing()
        textStorage.setAttributes(base, range: fullRange)

        if styleKind == .code || styleKind == .source {
            applyCodeHighlighting(
                in: textStorage,
                language: language,
                highlighter: highlighter,
                textView: textView,
                baseAttributes: base,
                baseFont: baseFont
            )
            textView.typingAttributes = base
        } else {
            applyMarkdownRule(.bold, in: textStorage) { match in
                textStorage.addAttributes([.font: boldFont(from: baseFont)], range: match.contentRange)
            }

            applyMarkdownRule(.boldUnderscore, in: textStorage) { match in
                textStorage.addAttributes([.font: boldFont(from: baseFont)], range: match.contentRange)
            }

            applyMarkdownRule(.italic, in: textStorage) { match in
                textStorage.addAttributes([.font: italicFont(from: baseFont)], range: match.contentRange)
            }

            applyMarkdownRule(.italicUnderscore, in: textStorage) { match in
                textStorage.addAttributes([.font: italicFont(from: baseFont)], range: match.contentRange)
            }

            applyMarkdownRule(.code, in: textStorage) { match in
                textStorage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: max(baseFont.pointSize - 1, 12), weight: .regular)
                ], range: match.contentRange)
            }

            applyMarkdownRule(.strikethrough, in: textStorage) { match in
                textStorage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue], range: match.contentRange)
            }

            applyMarkdownRule(.link, in: textStorage) { match in
                textStorage.addAttributes([
                    .foregroundColor: accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], range: match.contentRange)
            }
        }

        textStorage.endEditing()
        applyHiddenMarkerGlyphs(in: textView, projection: projection, hideMarkdownMarkers: hideMarkdownMarkers)
    }

    private static func lineSpacing(for kind: DocumentBlockKind) -> CGFloat {
        switch kind {
        case .heading1: return 0
        case .heading2: return 0.5
        case .heading3: return 0.5
        case .code, .source: return 1
        default: return 2
        }
    }

    private static func applyMarkdownRule(_ rule: BlockMarkdownCodec.InlineMarkdownRule, in textStorage: NSTextStorage, handler: (BlockMarkdownCodec.InlineMarkdownMatch) -> Void) {
        for match in rule.matches(in: textStorage.string) {
            handler(match)
        }
    }

    private static func boldFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italicFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func applyCodeHighlighting(
        in textStorage: NSTextStorage,
        language: String?,
        highlighter: any CodeSyntaxHighlighting,
        textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any],
        baseFont: NSFont
    ) {
        guard let normalizedLanguage = CodeSyntaxHighlightingService.normalizedLanguage(language) else {
            return
        }

        let highlighted = highlighter.highlightedString(
            code: textStorage.string,
            language: normalizedLanguage,
            appearance: appearance(for: textView),
            fontSize: baseFont.pointSize
        )

        guard highlighted.length == textStorage.length else {
            return
        }

        highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length), options: []) { attributes, range, _ in
            var mergedAttributes = attributes
            mergedAttributes.removeValue(forKey: .backgroundColor)
            mergedAttributes[.paragraphStyle] = baseAttributes[.paragraphStyle]
            if mergedAttributes[.font] == nil {
                mergedAttributes[.font] = baseAttributes[.font]
            }
            if mergedAttributes[.foregroundColor] == nil {
                mergedAttributes[.foregroundColor] = baseAttributes[.foregroundColor]
            }
            textStorage.addAttributes(mergedAttributes, range: range)
        }
    }

    private static func appearance(for textView: NSTextView) -> CodeHighlightAppearance {
        let match = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    private static func applyHiddenMarkerGlyphs(in textView: NSTextView, projection: BlockInlineMarkdownProjection, hideMarkdownMarkers: Bool) {
        let fullCharacterRange = NSRange(location: 0, length: (textView.string as NSString).length)

        if let blockTextView = textView as? BlockEditorTextView {
            blockTextView.layoutManager?.delegate = blockTextView
            blockTextView.hiddenMarkdownMarkerIndexes = hideMarkdownMarkers ? projection.hiddenMarkdownMarkerIndexes : IndexSet()
        }

        guard let layoutManager = textView.layoutManager else { return }
        if let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }

        layoutManager.invalidateDisplay(forCharacterRange: fullCharacterRange)
        layoutManager.invalidateLayout(forCharacterRange: fullCharacterRange, actualCharacterRange: nil)
        textView.needsDisplay = true
    }
}