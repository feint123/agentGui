//
//  BlockEditorTheme.swift
//  agentGui
//

import SwiftUI

enum BlockEditorTheme {
    static let contentWidth: CGFloat = 760
    static let contentPadding: CGFloat = 28
    static let blockCornerRadius: CGFloat = 12
    static let gutterWidth: CGFloat = 36
    static let specialBlockCornerRadius: CGFloat = 14

    // Colors that adapt automatically
    static let subtleText = Color.secondary.opacity(0.7)
    static let handleTint = Color.secondary.opacity(0.4)
    static let handleHoverTint = Color.secondary.opacity(0.7)
    static let blockSelectionTint = Color.accentColor.opacity(0.12)

    // Environment-dependent colors
    static func blockHoverTint(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.012)
    }

    static func blockBorder(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.038)
    }

    static func emphasisBackground(scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.primary.opacity(0.016)
    }

    static func pageBackground(for scheme: ColorScheme) -> some ShapeStyle {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(white: 0.11),
                    Color(white: 0.13),
                    Color(white: 0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(NSColor.windowBackgroundColor),
                Color(NSColor.textBackgroundColor),
                Color(red: 0.98, green: 0.97, blue: 0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func blockBackground(isActive: Bool, isHovered: Bool, emphasis: Bool, scheme: ColorScheme) -> AnyShapeStyle {
        if emphasis {
            return AnyShapeStyle(emphasisBackground(scheme: scheme))
        }
        if isActive {
            return AnyShapeStyle(blockSelectionTint)
        }
        if isHovered {
            return AnyShapeStyle(blockHoverTint(scheme: scheme))
        }
        return AnyShapeStyle(Color.clear)
    }

    static func specialBlockFill(tint: Color, isActive: Bool, isHovered: Bool, scheme: ColorScheme = .light) -> some ShapeStyle {
        let baseOpacity: Double
        if scheme == .dark {
            baseOpacity = isActive ? 0.18 : isHovered ? 0.14 : 0.10
        } else {
            baseOpacity = isActive ? 0.085 : isHovered ? 0.062 : 0.045
        }
        return tint.opacity(baseOpacity)
    }

    static func specialBlockBorder(tint: Color, isActive: Bool, isHovered: Bool, scheme: ColorScheme = .light) -> Color {
        let baseOpacity: Double
        if scheme == .dark {
            baseOpacity = isActive ? 0.32 : isHovered ? 0.22 : 0.15
        } else {
            baseOpacity = isActive ? 0.18 : isHovered ? 0.12 : 0.08
        }
        return tint.opacity(baseOpacity)
    }
}
