//
//  MarkdownMessageView.swift
//  agentGui
//
//  Created by feint on 2026/2/10.
//

import SwiftUI
import AppKit

// MARK: - Markdown Message View

/// 块级 Markdown 渲染视图，将消息分割为文本段和代码块段分别渲染
struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseSegments(text)) { segment in
                switch segment.kind {
                case .markdown:
                    markdownText(segment.content)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language):
                    CodeBlockView(code: segment.content, language: language)
                }
            }
        }
    }

    private func markdownText(_ raw: String) -> Text {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return Text("") }
        if let attr = try? AttributedString(
            markdown: trimmed,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(trimmed)
    }

    // MARK: - Segment Parsing

    private func parseSegments(_ input: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var remaining = input
        let pattern = #"```([^\n`]*)\n([\s\S]*?)```"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [MessageSegment(kind: .markdown, content: input)]
        }

        var searchRange = remaining.startIndex..<remaining.endIndex

        while true {
            let nsRange = NSRange(searchRange, in: remaining)
            guard let match = regex.firstMatch(in: remaining, range: nsRange) else {
                // 剩余全部作为 markdown 段
                let tail = String(remaining[searchRange])
                if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(MessageSegment(kind: .markdown, content: tail))
                }
                break
            }

            let matchRange = Range(match.range, in: remaining)!

            // 代码块之前的文本
            let before = String(remaining[searchRange.lowerBound..<matchRange.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(MessageSegment(kind: .markdown, content: before))
            }

            // 语言标签
            let langRange = match.range(at: 1)
            let language = langRange.location != NSNotFound
                ? (Range(langRange, in: remaining).map { String(remaining[$0]) } ?? "")
                : ""

            // 代码内容
            let codeRange = match.range(at: 2)
            let code = codeRange.location != NSNotFound
                ? (Range(codeRange, in: remaining).map { String(remaining[$0]) } ?? "")
                : ""

            segments.append(MessageSegment(kind: .code(language: language.isEmpty ? nil : language), content: code))

            searchRange = matchRange.upperBound..<remaining.endIndex
        }

        return segments.isEmpty ? [MessageSegment(kind: .markdown, content: input)] : segments
    }
}

// MARK: - Message Segment

private struct MessageSegment: Identifiable {
    let id = UUID()
    enum Kind {
        case markdown
        case code(language: String?)
    }
    let kind: Kind
    let content: String
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Label(isCopied ? "已复制" : "复制", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }
}
