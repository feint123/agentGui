//  AttachmentPillView.swift
//  agentGui

import SwiftUI
import AppKit

// MARK: - ViewModel (testable, pure logic)

enum PillOpenBehavior: Equatable {
    case editReveal   // 跳转编辑器（project/focused 非媒体）
    case systemOpen   // NSWorkspace.shared.open（external 非媒体）
    case mediaViewer  // 打开 MediaViewerView（图片/PDF）
    case none         // missing 文件不响应
}

enum AttachmentPillViewModel {

    static func isMedia(_ entry: AttachmentSnapshotEntry) -> Bool {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        return kind == .image || kind == .pdf
    }

    static func labelText(for entry: AttachmentSnapshotEntry) -> String {
        FileReferencePillViewModel.labelText(for: entry)
    }

    static func iconName(for entry: AttachmentSnapshotEntry) -> String {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        switch kind {
        case .sourceCode:  return "doc.text"
        case .image:       return "photo"
        case .pdf:         return "doc.richtext"
        case .directory:   return "folder"
        case .other:       return FileIconSymbolResolver.symbol(forFileName: entry.displayName)
        }
    }

    /// Option+Click 代码预览仅支持 project/focused 来源的非媒体文件。
    static func supportsPreview(_ entry: AttachmentSnapshotEntry) -> Bool {
        guard !isMedia(entry) else { return false }
        let origin = AttachmentOrigin(rawValue: entry.originRaw) ?? .external
        return origin == .project || origin == .focused
    }

    static func openBehavior(for entry: AttachmentSnapshotEntry) -> PillOpenBehavior {
        let status = AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
        guard status != .missing else { return .none }

        if isMedia(entry) { return .mediaViewer }

        let origin = AttachmentOrigin(rawValue: entry.originRaw) ?? .external
        switch origin {
        case .project, .focused: return .editReveal
        case .external:          return .systemOpen
        }
    }
}

// MARK: - Main Pill View

/// 统一的消息历史附件 pill。
/// 按 fileKindRaw 分发为 FileIconPill（代码/目录/其他）或 MediaThumbnailPill（图片/PDF）。
struct AttachmentPillView: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}
    var onMediaTap: (() -> Void)? = nil  // 图片/PDF 点击打开 viewer

    var body: some View {
        if AttachmentPillViewModel.isMedia(entry) {
            MediaThumbnailPill(entry: entry, onTap: onMediaTap ?? onTap)
        } else {
            FileIconPill(entry: entry, onTap: onTap)
        }
    }
}

// MARK: - FileIconPill（非媒体文件 pill）

/// 显示文件图标 + 名称 + 状态的 pill。复用 FileReferencePillView 的视觉语言，
/// 增加 origin-based 着色。
struct FileIconPill: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var isHovered = false
    @State private var showPreview = false

    private var origin: AttachmentOrigin {
        AttachmentOrigin(rawValue: entry.originRaw) ?? .external
    }
    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }
    private var tintColor: Color {
        AttachmentPillStyle.statusColor(origin: origin, status: status)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: AttachmentPillViewModel.iconName(for: entry))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tintColor.opacity(status == .valid ? 0.75 : 1.0))

            Group {
                if status == .missing {
                    Text(AttachmentPillViewModel.labelText(for: entry))
                        .strikethrough(true, color: .red.opacity(0.7))
                        .foregroundStyle(.red)
                } else {
                    Text(AttachmentPillViewModel.labelText(for: entry))
                        .foregroundStyle(status == .modified ? Color.yellow : .primary.opacity(0.8))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tintColor.opacity(AttachmentPillStyle.backgroundOpacity(status: status, hovered: isHovered)))
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor.opacity(AttachmentPillStyle.borderOpacity(status: status)), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if status == .modified {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: 4, y: -4)
            }
        }
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .onTapGesture { onTap() }
        .simultaneousGesture(
            TapGesture().modifiers(.option).onEnded { _ in
                if AttachmentPillViewModel.supportsPreview(entry) {
                    showPreview = true
                }
            }
        )
        .popover(isPresented: $showPreview, arrowEdge: .bottom) {
            FileReferencePreviewPopover(entry: entry)
                .frame(width: 380, height: 240)
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(entry.filePath, inFileViewerRootedAtPath: "")
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.filePath, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
        }
        .help(entry.filePath)
    }
}

// MARK: - MediaThumbnailPill（图片/PDF 小缩略图 + 文件名 pill）

/// 小缩略图 + 文件名横向 pill，与 FileIconPill 视觉语言一致。
/// 增加 origin-based 边框着色和 missing 状态覆盖层。
struct MediaThumbnailPill: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var thumbnail: NSImage? = nil
    @State private var isHovered = false

    private var isPDF: Bool {
        (AttachmentKind(rawValue: entry.fileKindRaw) ?? .other) == .pdf
    }
    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }
    private var origin: AttachmentOrigin {
        AttachmentOrigin(rawValue: entry.originRaw) ?? .external
    }
    private var tintColor: Color {
        AttachmentPillStyle.statusColor(origin: origin, status: status)
    }

    var body: some View {
        HStack(spacing: 5) {
            // 小缩略图区域（18×18）
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tintColor.opacity(0.15))
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: isPDF ? "doc.richtext" : "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tintColor.opacity(status == .valid ? 0.75 : 1.0))
                }
                // Missing 遮罩
                if status == .missing {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red.opacity(0.4))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Group {
                if status == .missing {
                    Text(entry.displayName)
                        .strikethrough(true, color: .red.opacity(0.7))
                        .foregroundStyle(.red)
                } else {
                    Text(entry.displayName)
                        .foregroundStyle(status == .modified ? Color.yellow : .primary.opacity(0.8))
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tintColor.opacity(AttachmentPillStyle.backgroundOpacity(status: status, hovered: isHovered)))
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor.opacity(AttachmentPillStyle.borderOpacity(status: status)), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if status == .modified {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .offset(x: 4, y: -4)
            }
        }
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { hovered in
            withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
        }
        .onTapGesture { onTap() }
        .contextMenu {
            Button {
                NSWorkspace.shared.selectFile(entry.filePath, inFileViewerRootedAtPath: "")
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.filePath, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
        }
        .help(entry.filePath)
        .task { thumbnail = await mediaThumbImage(url: URL(fileURLWithPath: entry.filePath), targetWidth: 36) }
    }
}
