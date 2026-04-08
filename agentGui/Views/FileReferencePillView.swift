//  FileReferencePillView.swift
//  agentGui

import SwiftUI
import AppKit

/// 单个文件引用 pill chip。
/// 显示：文件图标 + 文件名（可选行号）+ 状态指示。
/// 交互：单击跳转编辑器；Option+Click 弹出代码预览 popover。
struct FileReferencePillView: View {
    let entry: AttachmentSnapshotEntry
    var onTap: () -> Void = {}

    @State private var isHovered = false
    @State private var showPreview = false

    private var status: AttachmentStatus {
        AttachmentStatus(rawValue: entry.statusRaw) ?? .valid
    }

    var body: some View {
        pillContent
            .overlay(alignment: .topTrailing) {
                if status == .modified {
                    modifiedBadge
                }
            }
            .onHover { hovered in
                withAnimation(ChatMotion.hoverSpring) { isHovered = hovered }
            }
            .onTapGesture {
                onTap()
            }
            .simultaneousGesture(
                // Option+Click → 弹代码预览
                TapGesture().modifiers(.option).onEnded { _ in showPreview = true }
            )
            .popover(isPresented: $showPreview, arrowEdge: .bottom) {
                FileReferencePreviewPopover(entry: entry)
                    .frame(width: 380, height: 240)
            }
            .help(entry.filePath)
    }

    // MARK: - Pill 主体

    private var pillContent: some View {
        HStack(spacing: 5) {
            // 文件类型图标
            Image(systemName: fileIconName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconForeground)

            // 文件名 [+行号]
            Group {
                if status == .missing {
                    Text(labelText)
                        .strikethrough(true, color: .red.opacity(0.7))
                        .foregroundStyle(.red)
                } else {
                    Text(labelText)
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
                .fill(pillBackground)
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(pillBorderColor, lineWidth: 1)
        )
        .scaleEffect(isHovered ? ChatMotion.hoverScale : 1.0)
        .animation(ChatMotion.hoverSpring, value: isHovered)
    }

    // 修改标记角标
    private var modifiedBadge: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(.yellow)
            .offset(x: 4, y: -4)
    }

    // MARK: - Helpers

    private var labelText: String {
        FileReferencePillViewModel.labelText(for: entry)
    }

    private var fileIconName: String {
        let kind = AttachmentKind(rawValue: entry.fileKindRaw) ?? .other
        switch kind {
        case .sourceCode:  return "doc.text"
        case .image:       return "photo"
        case .pdf:         return "doc.richtext"
        case .directory:   return "folder"
        case .other:       return FileIconSymbolResolver.symbol(forFileName: entry.displayName)
        }
    }

    private var iconForeground: some ShapeStyle {
        switch status {
        case .valid:    return AnyShapeStyle(Color.accentColor.opacity(0.75))
        case .modified: return AnyShapeStyle(Color.yellow.opacity(0.85))
        case .missing:  return AnyShapeStyle(Color.red.opacity(0.7))
        }
    }

    private var pillBackground: some ShapeStyle {
        switch status {
        case .valid:    return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 0.12 : 0.07))
        case .modified: return AnyShapeStyle(Color.yellow.opacity(isHovered ? 0.15 : 0.08))
        case .missing:  return AnyShapeStyle(Color.red.opacity(isHovered ? 0.12 : 0.06))
        }
    }

    private var pillBorderColor: Color {
        switch status {
        case .valid:    return .accentColor.opacity(0.18)
        case .modified: return .yellow.opacity(0.30)
        case .missing:  return .red.opacity(0.25)
        }
    }
}

// MARK: - ViewModel helpers（逻辑可单测）

enum FileReferencePillViewModel {
    /// 生成显示文本：`filename` 或 `filename:start-end`
    static func labelText(for entry: AttachmentSnapshotEntry) -> String {
        guard let start = entry.lineStart else {
            return entry.displayName
        }
        if let end = entry.lineEnd, end != start {
            return "\(entry.displayName):\(start)-\(end)"
        }
        return "\(entry.displayName):\(start)"
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        Text("Valid").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/ClaudeService.swift",
            displayName: "ClaudeService.swift",
            fileKindRaw: "sourceCode", statusRaw: "valid",
            lineStart: 42, lineEnd: 68
        ))

        Text("Modified").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Message.swift",
            displayName: "Message.swift",
            fileKindRaw: "sourceCode", statusRaw: "modified"
        ))

        Text("Missing").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Gone.swift",
            displayName: "Gone.swift",
            fileKindRaw: "sourceCode", statusRaw: "missing"
        ))

        Text("Directory").font(.caption).foregroundStyle(.secondary)
        FileReferencePillView(entry: AttachmentSnapshotEntry(
            id: UUID(), filePath: "/a/Services/",
            displayName: "Services/",
            fileKindRaw: "directory", statusRaw: "valid"
        ))
    }
    .padding()
    .frame(width: 300)
}
