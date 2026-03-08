//
//  InlineStyleToolbarView.swift
//  agentGui
//
//  Floating inline-style toolbar that appears when text is selected in the block editor.
//  Uses Liquid Glass (glassEffect) on macOS 26+, with an ultraThinMaterial fallback.
//

import SwiftUI

struct InlineStyleToolbarView: View {
    let activeActions: Set<InlineStyleAction>
    let onAction: (InlineStyleAction) -> Void

    var body: some View {
        if #available(macOS 26, *) {
            glassToolbar
        } else {
            materialToolbar
        }
    }

    // MARK: - macOS 26+ Liquid Glass

    @available(macOS 26, *)
    private var glassToolbar: some View {
        GlassEffectContainer(spacing: 2) {
            toolbarButtons
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    // MARK: - Fallback (macOS 25 and earlier)

    private var materialToolbar: some View {
        toolbarButtons
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
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

    // MARK: - Shared button row

    private var toolbarButtons: some View {
        HStack(spacing: 2) {
            formatButton(.bold)
            formatButton(.italic)
            formatButton(.strikethrough)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 3)

            formatButton(.inlineCode)
        }
    }

    @ViewBuilder
    private func formatButton(_ action: InlineStyleAction) -> some View {
        if #available(macOS 26, *) {
            GlassFormatButton(
                action: action,
                isActive: activeActions.contains(action),
                onTap: onAction
            )
        } else {
            FallbackFormatButton(
                action: action,
                isActive: activeActions.contains(action),
                onTap: onAction
            )
        }
    }
}

// MARK: - macOS 26+ per-button (interactive glass)

@available(macOS 26, *)
private struct GlassFormatButton: View {
    let action: InlineStyleAction
    let isActive: Bool
    let onTap: (InlineStyleAction) -> Void

    var body: some View {
        Button {
            onTap(action)
        } label: {
            Image(systemName: action.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .help(action.tooltip)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
    }
}

// MARK: - Fallback per-button

private struct FallbackFormatButton: View {
    let action: InlineStyleAction
    let isActive: Bool
    let onTap: (InlineStyleAction) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onTap(action)
        } label: {
            Image(systemName: action.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(isHovered ? 1 : 0.8))
                .frame(width: 30, height: 28)
                .background(buttonBackground)
                .clipShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(action.tooltip)
        .scaleEffect(isHovered ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var buttonBackground: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        if isHovered {
            return AnyShapeStyle(Color.primary.opacity(0.1))
        }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - Transition helper (used by BlockDocumentEditor)

extension AnyTransition {
    static var inlineToolbar: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 6))
                .combined(with: .scale(scale: 0.92, anchor: .bottom)),
            removal: .opacity
                .combined(with: .scale(scale: 0.94, anchor: .bottom))
        )
    }
}
