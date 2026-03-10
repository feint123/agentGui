import Foundation
import SwiftUI

@MainActor
struct MarkdownMessageBlockPresentation {
    static func makeBlocks(from document: BlockDocument) -> [MarkdownMessageRenderBlock] {
        document.blocks.enumerated().map(makeBlock)
    }

    static func makeBlocks(from text: String) -> [MarkdownMessageRenderBlock] {
        let document = BlockMarkdownCodec.parse(text, fileURL: nil)
        return makeBlocks(from: document)
    }

    private static func makeBlock(index: Int, block: DocumentBlock) -> MarkdownMessageRenderBlock {
        let table = tableProjection(for: block)
        let kind = renderKind(for: block.kind)
        let metadata = MarkdownMessageRenderMetadata(
            language: block.metadata.language,
            resource: block.metadata.resource,
            secondaryText: block.metadata.secondaryText,
            calloutTone: block.metadata.tone,
            isCollapsed: block.metadata.isCollapsed,
            isChecked: block.metadata.checked,
            indentLevel: block.metadata.indentLevel,
            tableRows: table.rows,
            tableAlignments: table.alignments
        )
        let id = makeID(index: index, kind: kind, text: block.text, metadata: metadata)
        return MarkdownMessageRenderBlock(id: id, kind: kind, text: block.text, metadata: metadata)
    }

    private static func renderKind(for kind: DocumentBlockKind) -> MarkdownMessageRenderKind {
        switch kind {
        case .paragraph:
            return .paragraph
        case .heading1:
            return .heading(level: 1)
        case .heading2:
            return .heading(level: 2)
        case .heading3:
            return .heading(level: 3)
        case .quote:
            return .quote
        case .bulletedList:
            return .bulletedList
        case .numberedList:
            return .numberedList
        case .todo:
            return .todo
        case .code, .source:
            return .code
        case .divider:
            return .divider
        case .table:
            return .table
        case .image, .file:
            return .image
        case .url:
            return .url
        case .callout:
            return .callout
        case .toggle:
            return .toggle
        }
    }

    private static func makeID(index: Int, kind: MarkdownMessageRenderKind, text: String, metadata: MarkdownMessageRenderMetadata) -> String {
        let raw = [
            String(index),
            kind.idFragment,
            text,
            metadata.language,
            metadata.resource,
            metadata.secondaryText,
            metadata.calloutTone,
            metadata.isCollapsed ? "1" : "0",
            metadata.isChecked ? "1" : "0",
            String(metadata.indentLevel),
            metadata.tableRows.map { $0.joined(separator: "|") }.joined(separator: "\n"),
            metadata.tableAlignments.map(\.idFragment).joined(separator: ",")
        ].joined(separator: "::")
        return "md-\(index)-\(stableChecksum(raw))"
    }

    private static func stableChecksum(_ raw: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for scalar in raw.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func tableProjection(for block: DocumentBlock) -> (rows: [[String]], alignments: [HorizontalAlignment]) {
        guard block.kind == .table else {
            return ([], [])
        }

        let rows = BlockMarkdownCodec.parseTableContent(block.text)
        let lines = block.text.components(separatedBy: .newlines)
        let separator = lines.count > 1 ? parseTableCells(lines[1]) : []
        let alignments = separator.map(tableAlignment)
        return (rows, alignments)
    }

    private static func parseTableCells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let inner = trimmed.hasPrefix("|") ? String(trimmed.dropFirst()) : trimmed
        let stripped = inner.hasSuffix("|") ? String(inner.dropLast()) : inner
        return stripped.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAlignment(_ cell: String) -> HorizontalAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") {
            return .center
        }
        if trimmed.hasSuffix(":") {
            return .trailing
        }
        return .leading
    }
}

@MainActor
struct MarkdownMessageRenderBlock: Identifiable, Equatable {
    let id: String
    let kind: MarkdownMessageRenderKind
    let text: String
    let metadata: MarkdownMessageRenderMetadata

    var language: String? {
        metadata.language.isEmpty ? nil : metadata.language
    }

    var resource: String { metadata.resource }
    var secondaryText: String { metadata.secondaryText }
    var calloutTone: String { metadata.calloutTone }
    var isCollapsed: Bool { metadata.isCollapsed }
    var isChecked: Bool { metadata.isChecked }
    var indentLevel: Int { metadata.indentLevel }
    var tableRows: [[String]] { metadata.tableRows }
    var tableAlignments: [HorizontalAlignment] { metadata.tableAlignments }
}

@MainActor
enum MarkdownMessageRenderKind: Equatable {
    case paragraph
    case heading(level: Int)
    case quote
    case bulletedList
    case numberedList
    case todo
    case code
    case divider
    case table
    case image
    case url
    case callout
    case toggle

    fileprivate var idFragment: String {
        switch self {
        case .paragraph:
            return "paragraph"
        case .heading(let level):
            return "heading-\(level)"
        case .quote:
            return "quote"
        case .bulletedList:
            return "bulleted-list"
        case .numberedList:
            return "numbered-list"
        case .todo:
            return "todo"
        case .code:
            return "code"
        case .divider:
            return "divider"
        case .table:
            return "table"
        case .image:
            return "image"
        case .url:
            return "url"
        case .callout:
            return "callout"
        case .toggle:
            return "toggle"
        }
    }
}

@MainActor
struct MarkdownMessageRenderMetadata: Equatable {
    var language: String = ""
    var resource: String = ""
    var secondaryText: String = ""
    var calloutTone: String = "note"
    var isCollapsed = false
    var isChecked = false
    var indentLevel = 0
    var tableRows: [[String]] = []
    var tableAlignments: [HorizontalAlignment] = []
}

private extension HorizontalAlignment {
    var idFragment: String {
        switch self {
        case .leading:
            return "leading"
        case .center:
            return "center"
        case .trailing:
            return "trailing"
        default:
            return "other"
        }
    }
}