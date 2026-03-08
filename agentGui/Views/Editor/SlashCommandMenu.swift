//
//  SlashCommandMenu.swift
//  agentGui
//
//  Floating slash command menu using Liquid Glass (glassEffect) on macOS 26+,
//  with ultraThinMaterial fallback for earlier versions.
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
        if #available(macOS 26, *) {
            glassMenu
        } else {
            materialMenu
        }
    }

    // MARK: - macOS 26+ Liquid Glass

    @available(macOS 26, *)
    private var glassMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            divider
            scrollableItemList
        }
        .frame(width: 260, height: menuHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    // MARK: - Fallback (macOS 25 and earlier)

    private var materialMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            divider
            scrollableItemList
        }
        .frame(width: 260, height: menuHeight)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: - Height calculation

    private var menuHeight: CGFloat {
        let headerHeight: CGFloat = 44
        let dividerHeight: CGFloat = 1
        let itemHeight: CGFloat = 36
        let maxVisibleItems = 6
        let itemCount = min(items.count, maxVisibleItems)
        let listHeight = CGFloat(itemCount) * itemHeight + 8 // +8 for padding
        let maxListHeight = CGFloat(maxVisibleItems) * itemHeight + 8
        return headerHeight + dividerHeight + min(listHeight, maxListHeight)
    }

    private var scrollableItemList: some View {
        ScrollView {
            itemList
        }
        .frame(height: menuHeight - 45) // Subtract header + divider
    }

    // MARK: - Shared content

    private var headerSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BlockEditorTheme.subtleText)
            Text("插入块")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BlockEditorTheme.subtleText)
            Spacer()
            if !query.isEmpty {
                Text("/\(query)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 0.5)
            .padding(.horizontal, 8)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                menuItemButton(item)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menuItemButton(_ item: SlashCommandItem) -> some View {
        if #available(macOS 26, *) {
            glassMenuItem(item)
        } else {
            materialMenuItem(item)
        }
    }

    @available(macOS 26, *)
    private func glassMenuItem(_ item: SlashCommandItem) -> some View {
        Button {
            onSelect(item.kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(BlockEditorTheme.subtleText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13))
                    Text(item.keywords.prefix(2).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectedKind == item.kind ? Color.accentColor.opacity(0.15) : Color.clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func materialMenuItem(_ item: SlashCommandItem) -> some View {
        Button {
            onSelect(item.kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(BlockEditorTheme.subtleText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13))
                    Text(item.keywords.prefix(2).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selectedKind == item.kind ? Color.accentColor.opacity(0.15) : Color.clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transition

extension AnyTransition {
    static var editorFloatingMenu: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -6))
                .combined(with: .scale(scale: 0.94, anchor: .top)),
            removal: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
        )
    }
}
