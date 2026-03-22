import Foundation

struct BlockEditorSelectionSerializedPayload: Equatable {
    var markdown: String
    var plainText: String
    var html: String
    var internalJSON: String

    static let empty = BlockEditorSelectionSerializedPayload(
        markdown: "",
        plainText: "",
        html: "",
        internalJSON: ""
    )
}

enum BlockEditorSelectionSerializer {
    static func serialize(blocks: [DocumentBlock], fileURL: URL?) -> BlockEditorSelectionSerializedPayload {
        guard !blocks.isEmpty else { return .empty }

        let document = BlockDocument(blocks: blocks)
        let markdown = BlockMarkdownCodec.serialize(document, fileURL: fileURL)
        let plainText = blocks.map(plainTextFragment(for:)).joined(separator: "\n\n")
        let html = blocks.map(htmlFragment(for:)).joined(separator: "\n")
        let internalJSON = encodeInternalJSON(blocks)

        return BlockEditorSelectionSerializedPayload(
            markdown: markdown,
            plainText: plainText,
            html: html,
            internalJSON: internalJSON
        )
    }

    private static func encodeInternalJSON(_ blocks: [DocumentBlock]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(blocks),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private static func plainTextFragment(for block: DocumentBlock) -> String {
        switch block.kind {
        case .paragraph, .source:
            return block.text
        case .heading1, .heading2, .heading3:
            return block.text
        case .quote:
            return block.text
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
        case .bulletedList:
            return listLines(prefix: "- ", body: block.text)
        case .numberedList:
            return listLines(prefix: "1. ", body: block.text)
        case .todo:
            return listLines(prefix: block.metadata.checked ? "[x] " : "[ ] ", body: block.text)
        case .code:
            let language = block.metadata.language.isEmpty ? "plain" : block.metadata.language
            return "[代码: \(language)]\n\(block.text)"
        case .divider:
            return "---"
        case .table:
            return block.text
        case .image:
            let title = block.metadata.secondaryText.isEmpty ? "图片" : block.metadata.secondaryText
            return "[图片] \(title)\n\(block.metadata.resource)"
        case .url:
            let title = block.text.isEmpty ? (block.metadata.secondaryText.isEmpty ? "链接" : block.metadata.secondaryText) : block.text
            return "[链接] \(title)\n\(block.metadata.resource)"
        case .file:
            let title = block.text.isEmpty ? (block.metadata.secondaryText.isEmpty ? "附件" : block.metadata.secondaryText) : block.text
            return "[附件] \(title)\n\(block.metadata.resource)"
        case .callout:
            let title = block.metadata.secondaryText.isEmpty ? "提示" : block.metadata.secondaryText
            return "[提示: \(title)]\n\(block.text)"
        case .toggle:
            let title = block.metadata.secondaryText.isEmpty ? "折叠块" : block.metadata.secondaryText
            return "[折叠块: \(title)]\n\(block.text)"
        }
    }

    private static func htmlFragment(for block: DocumentBlock) -> String {
        switch block.kind {
        case .paragraph, .source:
            return "<p>\(escapeHTML(block.text))</p>"
        case .heading1:
            return "<h1>\(escapeHTML(block.text))</h1>"
        case .heading2:
            return "<h2>\(escapeHTML(block.text))</h2>"
        case .heading3:
            return "<h3>\(escapeHTML(block.text))</h3>"
        case .quote:
            let lines = block.text
                .components(separatedBy: .newlines)
                .map(escapeHTML)
                .joined(separator: "<br />")
            return "<blockquote>\(lines)</blockquote>"
        case .bulletedList:
            return "<ul><li>\(escapeHTML(block.text))</li></ul>"
        case .numberedList:
            return "<ol><li>\(escapeHTML(block.text))</li></ol>"
        case .todo:
            return "<ul data-checked=\"\(block.metadata.checked ? "true" : "false")\"><li>\(escapeHTML(block.text))</li></ul>"
        case .code:
            let language = escapeHTML(block.metadata.language.isEmpty ? "plain" : block.metadata.language)
            return "<pre><code class=\"language-\(language)\">\(escapeHTML(block.text))</code></pre>"
        case .divider:
            return "<hr />"
        case .table:
            let rows = BlockMarkdownCodec.parseTableContent(block.text)
            guard let header = rows.first else {
                return "<table></table>"
            }
            let headerHTML = header.map { "<th>\(escapeHTML($0))</th>" }.joined()
            let bodyHTML = rows.dropFirst().map { row in
                "<tr>" + row.map { "<td>\(escapeHTML($0))</td>" }.joined() + "</tr>"
            }.joined()
            return "<table><thead><tr>\(headerHTML)</tr></thead><tbody>\(bodyHTML)</tbody></table>"
        case .image:
            let alt = escapeHTML(block.metadata.secondaryText.isEmpty ? "image" : block.metadata.secondaryText)
            let resource = escapeHTML(block.metadata.resource)
            return "<figure><img src=\"\(resource)\" alt=\"\(alt)\" /></figure>"
        case .url:
            let title = escapeHTML(block.text.isEmpty ? "链接" : block.text)
            let resource = escapeHTML(block.metadata.resource)
            return "<p><a href=\"\(resource)\">\(title)</a></p>"
        case .file:
            let title = escapeHTML(block.text.isEmpty ? (block.metadata.secondaryText.isEmpty ? "附件" : block.metadata.secondaryText) : block.text)
            let resource = escapeHTML(block.metadata.resource)
            return "<p><a href=\"\(resource)\">\(title)</a></p>"
        case .callout:
            let title = escapeHTML(block.metadata.secondaryText.isEmpty ? "提示" : block.metadata.secondaryText)
            let body = escapeHTML(block.text)
            return "<aside data-tone=\"\(escapeHTML(block.metadata.tone))\"><strong>\(title)</strong><p>\(body)</p></aside>"
        case .toggle:
            let title = escapeHTML(block.metadata.secondaryText.isEmpty ? "折叠块" : block.metadata.secondaryText)
            let body = escapeHTML(block.text)
            let openAttribute = block.metadata.isCollapsed ? "" : " open"
            return "<details\(openAttribute)><summary>\(title)</summary><p>\(body)</p></details>"
        }
    }

    private static func listLines(prefix: String, body: String) -> String {
        let lines = body.components(separatedBy: .newlines)
        guard let first = lines.first else { return prefix }
        if lines.count == 1 {
            return prefix + first
        }

        return ([prefix + first] + lines.dropFirst().map { "  " + $0 }).joined(separator: "\n")
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}