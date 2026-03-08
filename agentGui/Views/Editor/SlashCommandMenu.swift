//
//  SlashCommandMenu.swift
//  agentGui
//

import SwiftUI

struct SlashCommandMenu: View {
    let query: String
    let selectedKind: DocumentBlockKind?
    let onSelect: (DocumentBlockKind) -> Void

    private var items: [SlashCommandItem] {
        SlashCommandItem.filtered(matching: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("插入块")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BlockEditorTheme.subtleText)
                if !query.isEmpty {
                    Text("/\(query)")
                        .font(.caption2)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ForEach(items) { item in
                Button {
                    onSelect(item.kind)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbolName)
                            .frame(width: 16)
                            .foregroundStyle(BlockEditorTheme.subtleText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.keywords.prefix(2).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(BlockEditorTheme.subtleText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(selectedKind == item.kind ? Color.accentColor.opacity(0.12) : Color.clear)
                    .clipShape(.rect(cornerRadius: 10))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
        .modifier(EditorFloatingMenuContainer())
    }
}

struct EditorFloatingMenuContainer: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.bottom, 10)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(BlockEditorTheme.blockBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }
}

extension AnyTransition {
    static var editorFloatingMenu: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)).combined(with: .scale(scale: 0.985, anchor: .topLeading)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading))
        )
    }
}
