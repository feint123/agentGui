//  FileReferencePreviewPopover.swift
//  agentGui

import SwiftUI
import AppKit

/// 悬停/Option+Click 弹出的文件代码预览 popover。
/// 显示文件前 20 行，语法高亮，文件缺失时显示警告占位。
struct FileReferencePreviewPopover: View {
    let entry: AttachmentSnapshotEntry

    @State private var previewAttr: NSAttributedString? = nil
    @State private var isMissing = false
    @State private var isLoading = true

    private let maxPreviewLines = 20
    private let maxReadBytes = 5 * 1024 * 1024  // 5MB hard cap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
            Divider()
            previewBody
        }
        .background(.ultraThinMaterial)
        .task(id: entry.id) {
            await loadPreview()
        }
    }

    // MARK: - Header (file path)

    private var previewHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(entry.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Body

    @ViewBuilder
    private var previewBody: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isMissing {
            missingPlaceholder
        } else if let attr = previewAttr {
            ScrollView([.horizontal, .vertical]) {
                SyntaxHighlightedCodeTextView(
                    attributedString: attr,
                    textInsets: NSSize(width: 10, height: 8)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var missingPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.yellow)
            Text("文件不存在")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(entry.filePath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - File loading

    @MainActor
    private func loadPreview() async {
        isLoading = true
        isMissing = false
        previewAttr = nil

        let path = entry.filePath
        let fileURL = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            isMissing = true
            isLoading = false
            return
        }

        let snippet = await Task.detached(priority: .userInitiated) {
            Self.readFirstLines(url: fileURL, maxLines: 20, maxBytes: 5 * 1024 * 1024)
        }.value

        guard let snippet else {
            isMissing = true
            isLoading = false
            return
        }

        let language = CodeSyntaxHighlightingService.languageIdentifier(for: fileURL)
        let appearance: CodeHighlightAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light
        let highlighted = CodeSyntaxHighlightingService.shared.highlightedString(
            code: snippet,
            language: language,
            appearance: appearance,
            fontSize: 11.5
        )
        previewAttr = highlighted
        isLoading = false
    }

    /// 读取文件前 `maxLines` 行，限制读入字节数防止大文件卡 UI 线程。
    nonisolated private static func readFirstLines(url: URL, maxLines: Int, maxBytes: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let data = fh.readData(ofLength: maxBytes)
        guard let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                       .prefix(maxLines)
        return lines.joined(separator: "\n")
    }
}
