import AppKit
import Foundation

/// 括号对着色服务（opt-in）。
/// 在 viewport 文本范围内，对不同嵌套深度的括号对应用不同颜色（6 色循环）。
/// 通过 NSLayoutManager.addTemporaryAttribute 应用，不修改 NSTextStorage。
struct CodeEditorBracketPairColorizationService: Sendable {

    /// 6 种括号对颜色（可主题化，首轮使用系统颜色近似）
    static let paletteColors: [NSColor] = [
        NSColor(calibratedRed: 0.97, green: 0.79, blue: 0.18, alpha: 1.0), // yellow
        NSColor(calibratedRed: 0.27, green: 0.69, blue: 0.95, alpha: 1.0), // cyan
        NSColor(calibratedRed: 0.62, green: 0.45, blue: 0.98, alpha: 1.0), // purple
        NSColor(calibratedRed: 0.33, green: 0.85, blue: 0.48, alpha: 1.0), // green
        NSColor(calibratedRed: 0.97, green: 0.53, blue: 0.32, alpha: 1.0), // orange
        NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.64, alpha: 1.0), // pink
    ]

    /// bracket 字符集（开和闭，索引对应）
    private static let openBrackets: [UInt16] = [
        UInt16(("(" as UnicodeScalar).value),
        UInt16(("[" as UnicodeScalar).value),
        UInt16(("{" as UnicodeScalar).value),
    ]
    private static let closeBrackets: [UInt16] = [
        UInt16((")" as UnicodeScalar).value),
        UInt16(("]" as UnicodeScalar).value),
        UInt16(("}" as UnicodeScalar).value),
    ]

    /// 为给定的 NSTextView 区间 [rangeStart, rangeEnd)（utf16 offset）着色。
    /// 扫描从文档开头到 rangeEnd，追踪全局嵌套深度，仅对 rangeStart..rangeEnd 区间内的括号应用颜色。
    /// - Parameters:
    ///   - textView: 目标 NSTextView（含 layoutManager）
    ///   - visibleUTF16Range: 只对此范围内的括号着色（viewport window）
    static func colorize(
        textView: NSTextView,
        visibleUTF16Range: NSRange
    ) {
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string
        let utf16 = Array(text.utf16)
        let totalLength = utf16.count

        let safeRangeStart = max(0, min(visibleUTF16Range.location, totalLength))
        let safeRangeEnd = max(safeRangeStart, min(visibleUTF16Range.location + visibleUTF16Range.length, totalLength))
        guard safeRangeEnd > safeRangeStart else { return }
        let safeRange = NSRange(location: safeRangeStart, length: safeRangeEnd - safeRangeStart)

        // 移除旧的 pairColorization 标记
        layoutManager.removeTemporaryAttribute(.init("agentGui.bracketPairColor"), forCharacterRange: safeRange)

        // 从文档头扫描到 safeRangeEnd，追踪全局深度
        // 对在 safeRange 内的每个括号字符应用颜色
        var globalDepth = 0  // 全局混合深度（所有括号类型共用）
        var i = 0
        while i < safeRangeEnd {
            let ch = utf16[i]
            if openBrackets.contains(ch) {
                let color = paletteColors[globalDepth % paletteColors.count]
                globalDepth += 1
                if i >= safeRangeStart {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                    layoutManager.addTemporaryAttribute(
                        .init("agentGui.bracketPairColor"),
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                }
            } else if closeBrackets.contains(ch) {
                globalDepth = max(0, globalDepth - 1)
                let color = paletteColors[globalDepth % paletteColors.count]
                if i >= safeRangeStart {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor,
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                    layoutManager.addTemporaryAttribute(
                        .init("agentGui.bracketPairColor"),
                        value: color,
                        forCharacterRange: NSRange(location: i, length: 1)
                    )
                }
            }
            i += 1
        }
    }
}
