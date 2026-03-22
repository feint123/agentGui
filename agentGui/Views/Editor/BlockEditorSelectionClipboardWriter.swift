import AppKit
import UniformTypeIdentifiers

enum BlockEditorSelectionClipboardWriter {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")
    static let internalJSONType = NSPasteboard.PasteboardType("com.feint.agentgui.block-selection+json")

    static func write(_ payload: BlockEditorSelectionSerializedPayload, preferredFormat: BlockEditorSelectionExportFormat = .plainText) {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()

        item.setString(payload.plainText, forType: .string)
        if !payload.markdown.isEmpty {
            item.setString(payload.markdown, forType: markdownType)
        }
        if !payload.html.isEmpty {
            item.setString(payload.html, forType: .html)
        }
        if !payload.internalJSON.isEmpty {
            item.setString(payload.internalJSON, forType: internalJSONType)
        }

        switch preferredFormat {
        case .markdown:
            item.setString(payload.markdown.isEmpty ? payload.plainText : payload.markdown, forType: .string)
        case .plainText:
            item.setString(payload.plainText, forType: .string)
        case .html:
            item.setString(payload.html.isEmpty ? payload.plainText : payload.html, forType: .string)
        }

        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}