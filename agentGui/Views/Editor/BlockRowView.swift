//
//  BlockRowView.swift
//  agentGui
//

import SwiftUI

struct BlockRowView: View {
    @Binding var block: DocumentBlock
    let focusRequest: BlockEditorFocusRequest?
    let isActive: Bool
    let mountHeavyEditor: Bool
    let listIndex: Int?
    let onTextChange: (String) -> Void
    let onEditorCommand: (BlockEditorCommand) -> Void
    let onFocusChange: (Bool) -> Void
    let onConvert: (DocumentBlockKind) -> Void
    let onFileDrop: ([URL]) -> Void
    var onSelectionChange: ((InlineSelectionState) -> Void)? = nil
    var onSlashContextChange: ((BlockEditorSlashContext?) -> Void)? = nil
    var pendingFormatRequest: InlineFormatRequest? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isEditingRawQuote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                dragHandle
                content
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalPadding)
        .background(backgroundStyle)
        .overlay(
            RoundedRectangle(cornerRadius: BlockEditorTheme.blockCornerRadius)
            .stroke(isActive ? Color.accentColor.opacity(0.055) : Color.clear, lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: BlockEditorTheme.blockCornerRadius))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .divider:
            dividerBlock

        case .table:
            tableBlock

        case .image:
            imageBlock

        case .url:
            urlBlock

        case .file:
            fileBlock

        case .callout:
            calloutBlock

        case .toggle:
            toggleBlock

        case .quote:
            quoteBlock

        default:
            editableTextBlock
        }
    }

    private var dragHandle: some View {
        ZStack {
            handleGlyph
        }
        .frame(width: BlockEditorTheme.gutterWidth, height: 24)
        .contentShape(Rectangle())
        .opacity(isHovered || isActive ? 0.95 : 0.08)
        .frame(width: BlockEditorTheme.gutterWidth)
        .padding(.top, 2)
    }

    private var editableTextBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsInlineMarker {
                inlineMarker
                    .frame(width: inlineMarkerWidth, alignment: .trailing)
                    .padding(.top, block.kind.isHeading ? 7 : 6)
            }

            Group {
                if mountHeavyEditor {
                    BlockTextEditor(
                        blockID: block.id,
                        text: $block.text,
                        placeholder: block.placeholder,
                        kind: block.kind,
                        focusRequest: focusRequest,
                        onTextChange: onTextChange,
                        onCommand: onEditorCommand,
                        onFileDrop: onFileDrop,
                        onFocusChange: onFocusChange,
                        onSelectionChange: onSelectionChange,
                        onSlashChange: onSlashContextChange,
                        pendingFormatRequest: pendingFormatRequest
                    )
                } else {
                    BlockReadOnlyTextContent(
                        text: block.text,
                        placeholder: block.placeholder,
                        kind: block.kind,
                        isChecked: block.metadata.checked
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, contentLeadingInset)
    }

    private var handleGlyph: some View {
        HStack(spacing: 2) {
            VStack(spacing: 2) {
                handleDot
                handleDot
                handleDot
            }
            VStack(spacing: 2) {
                handleDot
                handleDot
                handleDot
            }
        }
    }

    private var handleDot: some View {
        Circle()
            .fill(isHovered || isActive ? BlockEditorTheme.handleHoverTint : BlockEditorTheme.handleTint)
            .frame(width: 2, height: 2)
    }

    private var dividerBlock: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(maxWidth: .infinity)
            .frame(height: 1)
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private var metadataHeader: some View {
        HStack(spacing: 10) {
            Label(block.kind.title, systemImage: block.kind.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(BlockEditorTheme.subtleText)
            switch block.kind {
            case .todo:
                Button {
                    block.metadata.checked.toggle()
                    onTextChange(block.text)
                } label: {
                    Image(systemName: block.metadata.checked ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
            case .code, .source:
                TextField("语言", text: $block.metadata.language)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .frame(width: 120)
            case .callout:
                TextField("类型", text: $block.metadata.tone)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
                    .frame(width: 100)
                TextField("标题", text: $block.metadata.secondaryText)
                    .textFieldStyle(.plain)
            case .toggle:
                TextField("标题", text: $block.metadata.secondaryText)
                    .textFieldStyle(.plain)
                Button(block.metadata.isCollapsed ? "展开" : "折叠") {
                    block.metadata.isCollapsed.toggle()
                    onTextChange(block.text)
                }
                .buttonStyle(.borderless)
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .opacity(showsMetadataHeader ? 1 : 0)
        .frame(height: showsMetadataHeader ? nil : 0)
        .clipped()
    }

    @ViewBuilder
    private var inlineMarker: some View {
        switch block.kind {
        case .bulletedList:
            Circle()
                .fill(BlockEditorTheme.subtleText)
                .frame(width: 6, height: 6)
        case .numberedList:
            Text("\(listIndex ?? 1).")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(BlockEditorTheme.subtleText)
        case .todo:
            Button {
                block.metadata.checked.toggle()
                onTextChange(block.text)
            } label: {
                Image(systemName: block.metadata.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(block.metadata.checked ? Color.accentColor : BlockEditorTheme.subtleText)
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }

    private var tableBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            metadataHeader
            BlockTableEditor(markdown: $block.text)
                .onChange(of: block.text) { _, newValue in
                    onTextChange(newValue)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
    }

    private var imageBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isActive {
                HStack {
                    Label("图片", systemImage: "photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(BlockEditorTheme.subtleText)
                    Spacer(minLength: 0)
                }
                TextField("图片地址或本地路径", text: $block.metadata.resource)
                    .textFieldStyle(.roundedBorder)
                TextField("图片说明", text: $block.metadata.secondaryText)
                    .textFieldStyle(.roundedBorder)
            }
            if let resourceURL = resourceURL(from: block.metadata.resource), AttachedFile.pathIsImage(resourceURL.path) || resourceURL.scheme?.hasPrefix("http") == true {
                BlockImagePreview(resource: resourceURL)
            } else {
                Text(block.placeholder)
                    .font(.caption)
                    .foregroundStyle(BlockEditorTheme.subtleText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(secondarySurface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
    }

    private var urlBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isActive {
                Label("链接卡片", systemImage: "link")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BlockEditorTheme.subtleText)
                TextField("URL", text: $block.metadata.resource)
                    .textFieldStyle(.roundedBorder)
                TextField("标题", text: $block.text)
                    .textFieldStyle(.roundedBorder)
            }
            Link(destination: URL(string: block.metadata.resource) ?? URL(string: "https://example.com")!) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(block.text.isEmpty ? block.metadata.resource : block.text)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(block.metadata.resource)
                        .font(.caption)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(secondarySurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
    }

    private var fileBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("文件附件", systemImage: "doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(BlockEditorTheme.subtleText)
            TextField("标题", text: $block.text)
                .textFieldStyle(.roundedBorder)
            TextField("文件路径", text: $block.metadata.resource)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Image(systemName: AttachedFile.pathIsPDF(block.metadata.resource) ? "doc.richtext" : "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(block.text.isEmpty ? (block.metadata.resource as NSString).lastPathComponent : block.text)
                    Text(block.metadata.resource)
                        .font(.caption)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(secondarySurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 1)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
    }

    private var calloutBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(calloutColor.opacity(0.9))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(block.metadata.secondaryText.isEmpty ? "提示" : block.metadata.secondaryText, systemImage: "exclamationmark.bubble")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(calloutColor)

                    Group {
                        if mountHeavyEditor {
                            BlockTextEditor(
                                blockID: block.id,
                                text: $block.text,
                                placeholder: block.placeholder,
                                kind: .paragraph,
                                focusRequest: focusRequest,
                                onTextChange: onTextChange,
                                onCommand: onEditorCommand,
                                onFileDrop: onFileDrop,
                                onFocusChange: onFocusChange
                            )
                        } else {
                            BlockReadOnlyTextContent(
                                text: block.text,
                                placeholder: block.placeholder,
                                kind: .paragraph,
                                isChecked: false
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: calloutColor))
        .overlay(specialBlockStroke(tint: calloutColor))
    }

    private var toggleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                block.metadata.isCollapsed.toggle()
                onTextChange(block.text)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: block.metadata.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BlockEditorTheme.subtleText)
                    Text(block.metadata.secondaryText.isEmpty ? "折叠标题" : block.metadata.secondaryText)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !block.metadata.isCollapsed {
                Group {
                    if mountHeavyEditor {
                        BlockTextEditor(
                            blockID: block.id,
                            text: $block.text,
                            placeholder: block.placeholder,
                            kind: .paragraph,
                            focusRequest: focusRequest,
                            onTextChange: onTextChange,
                            onCommand: onEditorCommand,
                            onFileDrop: onFileDrop,
                            onFocusChange: onFocusChange
                        )
                    } else {
                        BlockReadOnlyTextContent(
                            text: block.text,
                            placeholder: block.placeholder,
                            kind: .paragraph,
                            isChecked: false
                        )
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
    }

    private var backgroundStyle: AnyShapeStyle {
        if block.kind == .divider {
            return AnyShapeStyle(Color.clear)
        }
        return AnyShapeStyle(BlockEditorTheme.blockBackground(isActive: isActive, isHovered: isHovered, emphasis: false, scheme: colorScheme))
    }

    private var calloutColor: Color {
        switch block.metadata.tone.lowercased() {
        case "warning": return .orange
        case "danger": return .red
        case "success": return .green
        default: return .blue
        }
    }

    private func resourceURL(from text: String) -> URL? {
        guard !text.isEmpty else { return nil }

        // Handle HTTP/HTTPS URLs
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            // Try direct URL first
            if let url = URL(string: text) {
                return url
            }
            // If that fails, try encoding the URL
            if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: encoded) {
                return url
            }
            return nil
        }

        // Handle file paths (both absolute and relative)
        // Expand tilde for home directory
        let expandedPath = NSString(string: text).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath)
    }

    private var showsMetadataHeader: Bool {
        switch block.kind {
        case .code, .source:
            return true
        default:
            return false
        }
    }

    private var contentLeadingInset: CGFloat {
        switch block.kind {
        case .bulletedList, .numberedList, .todo:
            return CGFloat(block.metadata.indentLevel) * 20
        default:
            return 0
        }
    }

    // MARK: - Quote block

    private var quoteBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 999)
                .fill(quoteBarColor)
                .frame(width: 3)

            Group {
                if isEditingRawQuote || mountHeavyEditor {
                    BlockTextEditor(
                        blockID: block.id,
                        text: $block.text,
                        placeholder: block.placeholder,
                        kind: .quote,
                        focusRequest: focusRequest,
                        onTextChange: onTextChange,
                        onCommand: onEditorCommand,
                        onFileDrop: onFileDrop,
                        onFocusChange: { isFocused in
                            onFocusChange(isFocused)
                            if !isFocused { isEditingRawQuote = false }
                        },
                        onSelectionChange: onSelectionChange,
                        pendingFormatRequest: pendingFormatRequest
                    )
                } else {
                    QuoteRenderedContent(
                        text: block.text,
                        depth: 1,
                        placeholder: block.placeholder,
                        onTap: { isEditingRawQuote = true }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .padding(.leading, CGFloat(block.metadata.indentLevel) * 16)
        .background(specialBlockBackground(tint: .gray))
        .overlay(specialBlockStroke(tint: .gray))
        .onAppear {
            if block.text.isEmpty { isEditingRawQuote = true }
        }
    }

    private var quoteBarColor: Color {
        switch block.metadata.indentLevel % 3 {
        case 1: return Color.accentColor.opacity(0.5)
        case 2: return Color.secondary.opacity(0.35)
        default: return Color.secondary.opacity(0.55)
        }
    }

    private var showsInlineMarker: Bool {
        block.kind == .bulletedList || block.kind == .numberedList || block.kind == .todo
    }

    private var inlineMarkerWidth: CGFloat {
        switch block.kind {
        case .bulletedList:
            return 16
        case .numberedList:
            let digits = max(2, String(listIndex ?? 1).count + 1)
            return CGFloat(digits * 8)
        case .todo:
            return 22
        default:
            return 0
        }
    }

    private var verticalPadding: CGFloat {
        if block.kind == .divider {
            return 0
        }
        if block.kind.isHeading {
            return 0.5
        }
        return 2
    }

    private func specialBlockBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: BlockEditorTheme.specialBlockCornerRadius)
            .fill(BlockEditorTheme.specialBlockFill(tint: tint, isActive: isActive, isHovered: isHovered, scheme: colorScheme))
    }

    private func specialBlockStroke(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: BlockEditorTheme.specialBlockCornerRadius)
            .stroke(BlockEditorTheme.specialBlockBorder(tint: tint, isActive: isActive, isHovered: isHovered, scheme: colorScheme), lineWidth: 1)
    }

    private var secondarySurface: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.primary.opacity(0.028)
    }
}

private struct BlockReadOnlyTextContent: View {
    let text: String
    let placeholder: String
    let kind: DocumentBlockKind
    let isChecked: Bool

    var body: some View {
        Group {
            if trimmedText.isEmpty {
                Text(placeholder)
                    .font(displayFont)
                    .foregroundStyle(BlockEditorTheme.subtleText)
            } else if kind == .code || kind == .source {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            } else {
                InlineMarkdownText(
                    text: text,
                    font: displayFont,
                    color: textColor,
                    strikethrough: kind == .todo && isChecked
                )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, kind.isHeading ? 2 : 4)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayFont: Font {
        switch kind {
        case .heading1:
            return .system(size: 26, weight: .bold)
        case .heading2:
            return .system(size: 20, weight: .semibold)
        case .heading3:
            return .system(size: 16, weight: .semibold)
        default:
            return .system(size: 14)
        }
    }

    private var textColor: Color {
        if kind == .todo && isChecked {
            return BlockEditorTheme.subtleText
        }
        return .primary
    }
}

// MARK: - Quote inline renderers

/// Read-only view that parses `text` as a BlockDocument and renders each block
/// inside a blockquote container. Tapping switches the parent to edit mode.
private struct QuoteRenderedContent: View {
    let text: String
    let depth: Int
    let placeholder: String
    let onTap: () -> Void

    private var innerDoc: BlockDocument {
        BlockMarkdownCodec.parse(text, fileURL: nil)
    }

    var body: some View {
        let doc = innerDoc
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(BlockEditorTheme.subtleText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(doc.blocks) { block in
                        QuoteInlineBlockView(block: block, depth: depth)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

/// Lightweight read-only renderer for a single block inside a blockquote.
/// Handles paragraphs, headings, lists, code, dividers, and nested quotes recursively.
private struct QuoteInlineBlockView: View {
    let block: DocumentBlock
    let depth: Int

    var body: some View {
        switch block.kind {
        case .heading1:
            inlineHeading(size: 20, weight: .bold)
        case .heading2:
            inlineHeading(size: 17, weight: .semibold)
        case .heading3:
            inlineHeading(size: 15, weight: .semibold)
        case .bulletedList:
            inlineBullet
        case .numberedList:
            inlineNumbered
        case .todo:
            inlineTodo
        case .code:
            inlineCode
        case .divider:
            Divider().padding(.vertical, 2)
        case .quote:
            inlineNestedQuote
        default:
            inlineParagraph
        }
    }

    // MARK: Inline renderers

    private var inlineParagraph: some View {
        InlineMarkdownText(text: block.text, font: .system(size: 14), color: .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func inlineHeading(size: CGFloat, weight: Font.Weight) -> some View {
        InlineMarkdownText(text: block.text, font: .system(size: size, weight: weight), color: .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var inlineBullet: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(BlockEditorTheme.subtleText)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            InlineMarkdownText(text: block.text, font: .system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(block.metadata.indentLevel) * 16)
    }

    private var inlineNumbered: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BlockEditorTheme.subtleText)
            InlineMarkdownText(text: block.text, font: .system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(block.metadata.indentLevel) * 16)
    }

    private var inlineTodo: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: block.metadata.checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(block.metadata.checked ? Color.accentColor : BlockEditorTheme.subtleText)
                .font(.system(size: 14))
            InlineMarkdownText(
                text: block.text,
                font: .system(size: 14),
                color: block.metadata.checked ? BlockEditorTheme.subtleText : .primary,
                strikethrough: block.metadata.checked
            )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(block.metadata.indentLevel) * 16)
    }

    private var inlineCode: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !block.metadata.language.isEmpty && block.metadata.language != "text" {
                Text(block.metadata.language)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BlockEditorTheme.subtleText)
            }
            Text(block.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.85))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var inlineNestedQuote: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 999)
                .fill(nestedBarColor)
                .frame(width: 3)
                .padding(.trailing, 10)
            if depth < 10 {
                let innerDoc = BlockMarkdownCodec.parse(block.text, fileURL: nil)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(innerDoc.blocks) { innerBlock in
                        QuoteInlineBlockView(block: innerBlock, depth: depth + 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private var nestedBarColor: Color {
        switch depth % 3 {
        case 0: return Color.secondary.opacity(0.35)
        case 1: return Color.accentColor.opacity(0.45)
        default: return Color.secondary.opacity(0.5)
        }
    }
}

private struct BlockImagePreview: View {
    let resource: URL

    @StateObject private var thumbnailLoader = EditorLocalThumbnailLoader()
    @State private var targetWidth: CGFloat = BlockEditorTheme.contentWidth

    var body: some View {
        Group {
            if resource.isFileURL {
                if let image = thumbnailLoader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else if thumbnailLoader.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    errorPlaceholder("无法加载本地图片")
                }
            } else if resource.scheme?.hasPrefix("http") == true {
                AsyncImage(url: resource) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure(let error):
                        errorPlaceholder(networkErrorDescription(error))
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    @unknown default:
                        ProgressView()
                    }
                }
            } else {
                errorPlaceholder("不支持的图片地址")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 280)
        .background(Color.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.04), lineWidth: 1)
        )
        .background(widthReader)
        .onAppear(perform: refreshThumbnail)
        .onChange(of: targetWidth) { _, _ in
            refreshThumbnail()
        }
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    updateTargetWidth(geo.size.width)
                }
                .onChange(of: geo.size.width) { _, newValue in
                    updateTargetWidth(newValue)
                }
        }
    }

    @ViewBuilder
    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if resource.scheme == "http" {
                Text("macOS 默认禁止 HTTP 连接，请使用 HTTPS")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
    }

    private func updateTargetWidth(_ width: CGFloat) {
        let resolvedWidth = max(120, width)
        if abs(targetWidth - resolvedWidth) > 1 {
            targetWidth = resolvedWidth
        }
    }

    private func refreshThumbnail() {
        guard resource.isFileURL else {
            thumbnailLoader.reset()
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnailLoader.load(fileURL: resource, targetWidth: targetWidth, scale: scale)
    }

    private func networkErrorDescription(_ error: Error) -> String {
        let errorStr = error.localizedDescription.lowercased()
        if errorStr.contains("unsupported") || errorStr.contains("format") {
            return "不支持的图片格式"
        } else if errorStr.contains("network") || errorStr.contains("connection") {
            return "网络连接失败"
        } else if errorStr.contains("certificate") || errorStr.contains("ssl") {
            return "SSL 证书验证失败"
        } else {
            return "图片加载失败"
        }
    }
}

private extension DocumentBlockKind {
    var isHeading: Bool {
        self == .heading1 || self == .heading2 || self == .heading3
    }
}
