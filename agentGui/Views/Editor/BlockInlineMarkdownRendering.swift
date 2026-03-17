import Foundation
import SwiftUI

enum BlockInlineMarkdownRendering {
    static func attributedString(for text: String) -> AttributedString? {
        guard !text.isEmpty else { return AttributedString("") }
        return try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    static func displayPlainText(for text: String) -> String {
        BlockInlineMarkdownProjection(sourceText: text).visibleText
    }
}

struct InlineMarkdownText: View {
    let text: String
    var font: Font? = nil
    var color: Color? = nil
    var strikethrough: Bool = false

    var body: some View {
        Group {
            if let attributed = BlockInlineMarkdownRendering.attributedString(for: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(color ?? .primary)
        .strikethrough(strikethrough)
    }
}