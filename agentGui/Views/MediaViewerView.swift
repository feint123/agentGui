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
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .task {
            nsImage = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
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
        .task { thumbnail = await mediaThumbImage(url: file.url) }
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
        .task { thumbnail = await mediaThumbImage(url: URL(fileURLWithPath: path)) }
    }
}

// MARK: - Shared thumbnail loading

func mediaThumbImage(url: URL) async -> NSImage? {
    await Task.detached(priority: .userInitiated) { [url] in
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext) {
            return NSImage(contentsOf: url)
        } else if ext == "pdf", let page = PDFDocument(url: url)?.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let targetSide: CGFloat = 144
            let scale = targetSide / max(bounds.width, bounds.height, 1)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            return NSImage(size: size, flipped: false) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(NSRect(origin: .zero, size: size))
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
                return true
            }
        }
        return nil
    }.value
}
