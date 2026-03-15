//
//  MediaViewerView.swift
//  agentGui
//

import SwiftUI
import PDFKit
import AppKit

// MARK: - MediaItem

struct MediaItem: Identifiable {
    let id = UUID()
    let url: URL

    var isImage: Bool { AttachedFile.pathIsImage(url.path) }
    var isPDF: Bool { AttachedFile.pathIsPDF(url.path) }
}

// MARK: - MediaViewerView

struct MediaViewerView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: item.isPDF ? "doc.richtext" : "photo")
                    .foregroundStyle(.secondary)
                Text(item.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            if item.isPDF {
                PDFKitView(url: item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MediaImageViewer(url: item.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}

// MARK: - MediaImageViewer

struct MediaImageViewer: View {
    let url: URL
    @State private var nsImage: NSImage? = nil
    @State private var errorMessage: String? = nil
    @State private var isLoading = true

    var body: some View {
        Group {
            if let img = nsImage {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if url.scheme == "http" {
                        Text("macOS 默认禁止 HTTP 连接，请使用 HTTPS")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .task {
            await loadImage()
        }
    }

    private func loadImage() async {
        isLoading = true
        errorMessage = nil

        // For network URLs, use URLSession to download
        if url.scheme?.hasPrefix("http") == true {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = NSImage(data: data) {
                    nsImage = image
                } else {
                    errorMessage = "无法解析图片数据"
                }
            } catch {
                errorMessage = errorDescription(error)
            }
        } else {
            // For local files, use NSImage directly on background thread
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            nsImage = image
            if nsImage == nil {
                errorMessage = "无法加载本地图片"
            }
        }

        isLoading = false
    }

    private func errorDescription(_ error: Error) -> String {
        let errorStr = error.localizedDescription.lowercased()
        if errorStr.contains("unsupported") || errorStr.contains("format") {
            return "不支持的图片格式"
        } else if errorStr.contains("network") || errorStr.contains("connection") {
            return "网络连接失败"
        } else if errorStr.contains("certificate") || errorStr.contains("ssl") {
            return "SSL 证书验证失败"
        } else {
            return "图片加载失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - PDFKitView

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.textBackgroundColor
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - FileThumbnailView (input area chip with remove button)

struct FileThumbnailView: View {
    let file: AttachedFile
    let onRemove: () -> Void
    let onTap: () -> Void

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailBody
                .onTapGesture { onTap() }

            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .task { thumbnail = await mediaThumbImage(url: file.url, targetWidth: 72) }
    }

    @ViewBuilder
    private var thumbnailBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: file.isPDF ? "doc.richtext" : "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            if file.isPDF {
                VStack {
                    Spacer()
                    Text("PDF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 5)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - MediaThumbnailCell (message bubble, tap to open viewer)

struct MediaThumbnailCell: View {
    let path: String
    let onTap: () -> Void

    @State private var thumbnail: NSImage? = nil
    private var isPDF: Bool { AttachedFile.pathIsPDF(path) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isPDF ? "doc.richtext" : "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            if isPDF {
                VStack {
                    Spacer()
                    Text("PDF")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 5)
                }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .onTapGesture { onTap() }
        .task { thumbnail = await mediaThumbImage(url: URL(fileURLWithPath: path), targetWidth: 80) }
    }
}

// MARK: - Shared thumbnail loading

func mediaThumbImage(url: URL, targetWidth: CGFloat = 144) async -> NSImage? {
    // For network URLs, download first then create thumbnail
    if url.scheme?.hasPrefix("http") == true {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return await createThumbnail(from: data, originalURL: url)
        } catch {
            return nil
        }
    } else {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = EditorLocalThumbnailRequest(fileURL: url, targetWidth: targetWidth, scale: scale)
        return await EditorLocalThumbnailPipeline.shared.image(for: request)
    }
}

private func createThumbnail(from data: Data, originalURL: URL) async -> NSImage? {
    await Task.detached(priority: .userInitiated) {
        let ext = originalURL.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            return NSImage(data: data)
        } else if ext == "pdf", let pdfDocument = PDFDocument(data: data), let page = pdfDocument.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let targetSide: CGFloat = 144
            let scale = targetSide / max(bounds.width, bounds.height, 1)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            return NSImage(size: size, flipped: false) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
                ctx.fill(NSRect(origin: .zero, size: size))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                return true
            }
        }
        return nil
    }.value
}
