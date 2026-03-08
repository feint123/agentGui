//
//  BlockEditorTheme.swift
//  agentGui
//

import SwiftUI

enum BlockEditorTheme {
    static let contentWidth: CGFloat = 760
    static let contentPadding: CGFloat = 28
    static let blockCornerRadius: CGFloat = 12
    static let blockHoverTint = Color.black.opacity(0.012)
    static let blockSelectionTint = Color.accentColor.opacity(0.028)
    static let blockBorder = Color.black.opacity(0.038)
    static let subtleText = Color.primary.opacity(0.5)
    static let handleTint = Color.primary.opacity(0.28)
    static let handleHoverTint = Color.primary.opacity(0.52)
    static let gutterWidth: CGFloat = 36
    static let specialBlockCornerRadius: CGFloat = 14

    static let pageBackground = LinearGradient(
        colors: [
            Color(NSColor.windowBackgroundColor),
            Color(NSColor.textBackgroundColor),
            Color(red: 0.98, green: 0.97, blue: 0.95)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static func blockBackground(isActive: Bool, isHovered: Bool, emphasis: Bool) -> AnyShapeStyle {
        if emphasis {
            return AnyShapeStyle(Color.primary.opacity(0.016))
        }
        if isActive {
            return AnyShapeStyle(blockSelectionTint)
        }
        if isHovered {
            return AnyShapeStyle(blockHoverTint)
        }
        return AnyShapeStyle(Color.clear)
    }

    static func specialBlockFill(tint: Color, isActive: Bool, isHovered: Bool) -> some ShapeStyle {
        tint.opacity(isActive ? 0.085 : isHovered ? 0.062 : 0.045)
    }

    static func specialBlockBorder(tint: Color, isActive: Bool, isHovered: Bool) -> Color {
        tint.opacity(isActive ? 0.18 : isHovered ? 0.12 : 0.08)
    }
}
