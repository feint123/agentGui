//
//  AttachmentEntryChipView.swift
//  agentGui
//
//  输入区统一附件 Chip — 替代 contextChip() / fileChip() / inputDirectiveChip() 三个独立实现。
//
//  参考:
//  - Open WebUI FileItem.svelte: dismissible prop + loading → Spinner 替代图标
//  - VS Code AbstractChatAttachmentWidget: 基类承担 dismiss 按钮 + aria 共享逻辑

import SwiftUI

// MARK: - Config（可测辅助结构，与 View 解耦）

/// `_ChipContainer` 的纯数据配置，用于单元测试和条件渲染判断。
struct ChipContainerConfig {
    let tint: Color
    let onRemove: (() -> Void)?

    var hasRemoveButton: Bool { onRemove != nil }

    static func isLoading(for status: AttachedFile.UploadStatus) -> Bool {
        status == .uploading
    }
}

// MARK: - Testable Helpers

/// @testable 可见的 tint 映射，避免在测试中实例化视图。
enum AttachmentOriginTint {
    static func color(for origin: AttachmentOrigin) -> Color {
        switch origin {
        case .focused:  return .orange
        case .project:  return .accentColor
        case .external: return .secondary
        }
    }
}

// MARK: - _ChipContainer（基础 chip 容器）

/// 所有输入区 chip 的底层容器。
/// 提供：ultraThinMaterial 背景、cornerRadius 8、0.10 边框、× 按钮（可选）、hover 缩放。
///
/// 对标 Open WebUI: `dismissible=false` → × 按钮不渲染；`loading=true` → content 区换 Spinner。
/// 对标 VS Code: AbstractChatAttachmentWidget 基类负责 dismiss + aria，内容子类注入。
struct _ChipContainer<Content: View>: View {
    let tint: Color
    var isLoading: Bool = false
    var onRemove: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            chipBody

            // × 按钮 — 仅 onRemove != nil 时渲染（对标 Open WebUI: dismissible 模式）
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .padding(1)
                        )
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .opacity(isHovered ? 1 : 0)            // hover 时才可见（对标 Open WebUI group-hover:visible）
                .accessibilityLabel("移除附件")
            }
        }
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
        .onHover { isHovered = $0 }
        // 入场动效
        .transition(
            .scale(scale: 0.85).combined(with: .opacity)
        )
    }

    private var chipBody: some View {
        HStack(spacing: 5) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                content()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

// MARK: - FileIconChip（文字文件、项目文件 @Mention、聚焦文件、指令）

/// 图标 + 名称样式的 chip，适用于非图片/PDF 文件及 inputDirective。
struct FileIconChip: View {
    let systemImage: String
    let label: String
    let tint: Color
    var isLoading: Bool = false
    var onRemove: (() -> Void)? = nil

    var body: some View {
        _ChipContainer(tint: tint, isLoading: isLoading, onRemove: onRemove) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(label)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.72))
                .lineLimit(1)
        }
    }
}

// MARK: - MediaThumbnailChip（图片 / PDF 缩略图）

/// 72×72 缩略图 chip，适用于图片和 PDF 附件。
/// 对标 Open WebUI: icon 区域在 loading 时切换到 Spinner，图标在 loaded 后替换为真实图片。
struct MediaThumbnailChip: View {
    let file: AttachedFile
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @State private var thumbnail: NSImage? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailBody
                .onTapGesture { onTap?() }

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .background(
                            Circle()
                                .fill(Color(NSColor.windowBackgroundColor))
                                .padding(1)
                        )
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("移除附件")
            }
        }
        .task { thumbnail = await mediaThumbImage(url: file.url, targetWidth: 72) }
        // 入场动效
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    @ViewBuilder
    private var thumbnailBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))

            if file.uploadStatus == .uploading {
                ProgressView()
                    .controlSize(.regular)
            } else if let img = thumbnail {
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - AttachmentEntryChipView（公开入口）

/// 输入区统一附件 chip 入口视图。
/// - 图片 / PDF → `MediaThumbnailChip`（缩略图）
/// - 其他文件 → `FileIconChip`（图标 + 文件名）
struct AttachmentEntryChipView: View {
    let file: AttachedFile
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        if file.isImage || file.isPDF {
            MediaThumbnailChip(file: file, onRemove: onRemove, onTap: onTap)
        } else {
            FileIconChip(
                systemImage: FileIconSymbolResolver.symbol(forFileName: file.name),
                label: file.name,
                tint: AttachmentOriginTint.color(for: file.origin),
                isLoading: file.uploadStatus == .uploading,
                onRemove: onRemove
            )
        }
    }
}
