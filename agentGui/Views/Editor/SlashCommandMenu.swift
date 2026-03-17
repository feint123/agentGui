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
    let categories: [BlockSlashCommandCategory]
    let highlightedCategoryID: BlockSlashMenuCategoryID?
    let selectedCategoryID: BlockSlashMenuCategoryID?
    let highlightedItemID: String?
    let scrollTargetItemID: String?
    let onScrollTargetConsumed: () -> Void
    let onSelectCategory: (BlockSlashMenuCategoryID) -> Void
    let onSelect: (BlockSlashCommandItem) -> Void

    @Namespace private var selectionAnimation

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
            contentColumns
        }
        .frame(width: menuWidth, height: menuHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: selectedCategoryID)
        .animation(.smooth(duration: 0.18), value: highlightedItemID)
    }

    // MARK: - Fallback (macOS 25 and earlier)

    private var materialMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            divider
            contentColumns
        }
        .frame(width: menuWidth, height: menuHeight)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: selectedCategoryID)
        .animation(.smooth(duration: 0.18), value: highlightedItemID)
    }

    // MARK: - Height calculation

    private var menuWidth: CGFloat {
        selectedCategory == nil ? BlockEditorFloatingOverlayLayout.menuCollapsedWidth : BlockEditorFloatingOverlayLayout.menuExpandedWidth
    }

    private var menuHeight: CGFloat {
        BlockEditorFloatingOverlayLayout.slashMenuSize(
            categoryCount: categories.count,
            selectedItemCount: selectedCategory?.items.count ?? 0,
            isExpanded: selectedCategory != nil
        ).height
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

    private var selectedCategory: BlockSlashCommandCategory? {
        guard let selectedCategoryID else { return nil }
        return categories.first(where: { $0.id == selectedCategoryID })
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 0.5)
            .padding(.horizontal, 8)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 0.5)
            .padding(.vertical, 8)
    }

    private var contentColumns: some View {
        HStack(alignment: .top, spacing: 0) {
            categoryColumn
            if selectedCategory != nil {
                verticalDivider
                    .transition(.opacity)
                itemColumn
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .scale(scale: 0.98, anchor: .trailing).combined(with: .opacity)
                        )
                    )
            }
        }
    }

    private var categoryColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(categories) { category in
                        Button {
                            onSelectCategory(category.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: category.symbolName)
                                    .frame(width: 16)
                                Text(category.title)
                                    .font(.system(size: 13, weight: .medium))
                                Spacer(minLength: 0)
                                Text("\(category.items.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(BlockEditorTheme.subtleText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(alignment: .leading) {
                                if category.id == highlightedCategoryID {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(category.id == selectedCategoryID ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08))
                                        .matchedGeometryEffect(id: "slash-category-selection", in: selectionAnimation)
                                }
                            }
                            .contentShape(.rect(cornerRadius: 8))
                        }
                        .id(category.id)
                        .buttonStyle(.plain)
                        .contentTransition(.interpolate)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: highlightedCategoryID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.smooth(duration: 0.16)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var itemColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let selectedCategory {
                        categoryDetailHeader(selectedCategory)
                        ForEach(selectedCategory.items) { item in
                            menuItemButton(item)
                                .id(item.id)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: scrollTargetItemID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.smooth(duration: 0.16)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
                onScrollTargetConsumed()
            }
        }
        .frame(width: 281)
        .clipped()
    }

    private func categoryDetailHeader(_ category: BlockSlashCommandCategory) -> some View {
        HStack(spacing: 8) {
            Label(category.title, systemImage: category.symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BlockEditorTheme.subtleText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func menuItemButton(_ item: BlockSlashCommandItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(BlockEditorTheme.subtleText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(BlockEditorTheme.subtleText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(alignment: .leading) {
                if highlightedItemID == item.id {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.15))
                        .matchedGeometryEffect(id: "slash-item-selection", in: selectionAnimation)
                }
            }
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contentTransition(.interpolate)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("没有匹配的块操作")
                .font(.system(size: 13, weight: .medium))
            Text("继续输入以缩小范围，或按 Esc 关闭。")
                .font(.caption)
                .foregroundStyle(BlockEditorTheme.subtleText)
        }
        .padding(10)
    }
}

// MARK: - Transition

extension AnyTransition {
    static var editorFloatingMenu: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -10))
                .combined(with: .scale(scale: 0.96, anchor: .topLeading)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .topLeading))
        )
    }
}
