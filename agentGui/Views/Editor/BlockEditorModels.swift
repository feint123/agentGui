//
//  BlockEditorModels.swift
//  agentGui
//

import Foundation

enum DocumentBlockKind: String, CaseIterable, Identifiable, Codable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case quote
    case bulletedList
    case numberedList
    case todo
    case code
    case divider
    case table
    case image
    case url
    case file
    case callout
    case toggle
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraph: return "正文"
        case .heading1: return "标题 1"
        case .heading2: return "标题 2"
        case .heading3: return "标题 3"
        case .quote: return "引用"
        case .bulletedList: return "无序列表"
        case .numberedList: return "有序列表"
        case .todo: return "待办"
        case .code: return "代码块"
        case .divider: return "分割线"
        case .table: return "表格"
        case .image: return "图片"
        case .url: return "链接卡片"
        case .file: return "文件附件"
        case .callout: return "提示块"
        case .toggle: return "折叠块"
        case .source: return "源码块"
        }
    }

    var symbolName: String {
        switch self {
        case .paragraph: return "text.alignleft"
        case .heading1, .heading2, .heading3: return "textformat.size"
        case .quote: return "quote.opening"
        case .bulletedList: return "list.bullet"
        case .numberedList: return "list.number"
        case .todo: return "checklist"
        case .code, .source: return "chevron.left.forwardslash.chevron.right"
        case .divider: return "minus"
        case .table: return "tablecells"
        case .image: return "photo"
        case .url: return "link"
        case .file: return "doc"
        case .callout: return "exclamationmark.bubble"
        case .toggle: return "chevron.right.circle"
        }
    }

    var slashKeywords: [String] {
        switch self {
        case .paragraph: return ["text", "paragraph", "正文"]
        case .heading1: return ["h1", "title", "heading", "一级标题"]
        case .heading2: return ["h2", "heading", "二级标题"]
        case .heading3: return ["h3", "heading", "三级标题"]
        case .quote: return ["quote", "blockquote", "引用"]
        case .bulletedList: return ["bullet", "list", "ul", "列表"]
        case .numberedList: return ["number", "ordered", "ol", "编号"]
        case .todo: return ["todo", "task", "checkbox", "待办"]
        case .code: return ["code", "fence", "代码"]
        case .divider: return ["divider", "hr", "line", "分割线"]
        case .table: return ["table", "grid", "表格"]
        case .image: return ["image", "photo", "图片"]
        case .url: return ["url", "link", "bookmark", "链接"]
        case .file: return ["file", "attachment", "附件"]
        case .callout: return ["callout", "note", "提示"]
        case .toggle: return ["toggle", "details", "collapse", "折叠"]
        case .source: return ["source", "plain", "raw", "源码"]
        }
    }

    var prefersMonospace: Bool {
        self == .code || self == .source || self == .table
    }

    var acceptsRichBody: Bool {
        self != .divider && self != .image && self != .url && self != .file
    }
}

struct DocumentBlockMetadata: Equatable, Codable {
    var checked = false
    var language = ""
    var resource = ""
    var secondaryText = ""
    var tone = "note"
    var isCollapsed = false
    var indentLevel = 0
}

struct DocumentBlock: Identifiable, Equatable, Codable {
    var id = UUID()
    var kind: DocumentBlockKind
    var text: String
    var metadata = DocumentBlockMetadata()

    static func empty(_ kind: DocumentBlockKind = .paragraph) -> DocumentBlock {
        var block = DocumentBlock(kind: kind, text: "")
        block.applyDefaults(for: kind)
        return block
    }

    mutating func applyDefaults(for kind: DocumentBlockKind) {
        switch kind {
        case .code:
            if metadata.language.isEmpty { metadata.language = "text" }
        case .callout:
            if metadata.tone.isEmpty { metadata.tone = "note" }
            if metadata.secondaryText.isEmpty { metadata.secondaryText = "提示" }
        case .toggle:
            if metadata.secondaryText.isEmpty { metadata.secondaryText = "折叠标题" }
        case .image:
            if metadata.secondaryText.isEmpty { metadata.secondaryText = "图片说明" }
        case .url:
            if metadata.secondaryText.isEmpty { metadata.secondaryText = "链接标题" }
        case .file:
            if metadata.secondaryText.isEmpty { metadata.secondaryText = "附件标题" }
        case .source:
            if metadata.language.isEmpty { metadata.language = "plain" }
        default:
            break
        }
    }
}

struct BlockDocument: Equatable {
    var blocks: [DocumentBlock]

    static let empty = BlockDocument(blocks: [.empty(.paragraph)])
}

struct SlashCommandItem: Identifiable, Equatable {
    let kind: DocumentBlockKind

    var id: DocumentBlockKind { kind }
    var title: String { kind.title }
    var symbolName: String { kind.symbolName }
    var keywords: [String] { kind.slashKeywords }

    static let all: [SlashCommandItem] = DocumentBlockKind.allCases.map(SlashCommandItem.init(kind:))

    static func filtered(matching query: String) -> [SlashCommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.title.localizedStandardContains(trimmed) || $0.keywords.contains { $0.localizedStandardContains(trimmed) }
        }
    }
}

enum BlockEditorFocusPosition: Equatable {
    case start
    case end
}

struct BlockEditorFocusRequest: Equatable {
    let blockID: UUID
    let position: BlockEditorFocusPosition
    let token = UUID()
}

extension DocumentBlock {
    var placeholder: String {
        switch kind {
        case .paragraph: return "输入正文，输入 / 插入块"
        case .heading1: return "一级标题"
        case .heading2: return "二级标题"
        case .heading3: return "三级标题"
        case .quote: return "引用内容"
        case .bulletedList: return "列表项"
        case .numberedList: return "编号项"
        case .todo: return "待办事项"
        case .code: return "输入代码"
        case .divider: return ""
        case .table: return "| 列 1 | 列 2 |\n| --- | --- |\n| 值 | 值 |"
        case .image: return "粘贴图片 URL 或拖入图片文件"
        case .url: return "粘贴链接地址"
        case .file: return "粘贴文件路径或拖入文件"
        case .callout: return "提示内容"
        case .toggle: return "折叠块内容"
        case .source: return "原始文本 / 源码"
        }
    }
}

// MARK: - Inline Style Toolbar Models

enum InlineStyleAction: String, Hashable, CaseIterable {
    case bold, italic, strikethrough, inlineCode

    var symbolName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var markdownWrap: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .inlineCode: return "`"
        }
    }

    var tooltip: String {
        switch self {
        case .bold: return "加粗"
        case .italic: return "斜体"
        case .strikethrough: return "删除线"
        case .inlineCode: return "行内代码"
        }
    }
}

struct InlineSelectionState: Equatable {
    let blockID: UUID
    let selectedRange: NSRange
    /// Rect in NSScreen coordinates reported by NSTextView.firstRect(forCharacterRange:)
    let selectionRect: CGRect
    let hasSelection: Bool
    let activeActions: Set<InlineStyleAction>
    /// The raw text of the current selection, if any.
    let selectedText: String?
}

/// One-shot format request; token ensures idempotent application inside updateNSView.
struct InlineFormatRequest: Equatable {
    let action: InlineStyleAction
    let token: UUID

    init(action: InlineStyleAction) {
        self.action = action
        self.token = UUID()
    }
}
