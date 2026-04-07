import AppKit

/// 多光标操作工具集。所有方法不持有任何状态，便于单测。
enum CodeEditorMultiSelectionController {

    static let maxCursorCount = 100

    // MARK: - 添加/移除光标

    /// 在 utf16Offset 处添加光标。若该处已是 zero-length 选区，则移除（Zed toggle 行为）。
    /// 限制总数不超过 maxCursorCount。
    /// - Returns: 新的 selectedRanges（已排序去重）
    static func toggleCursor(
        at utf16Offset: Int,
        in currentRanges: [NSRange]
    ) -> [NSRange] {
        let point = NSRange(location: utf16Offset, length: 0)
        // 若已有完全相同的 zero-length range，移除之（Zed toggle 语义）
        if let idx = currentRanges.firstIndex(where: { $0 == point }) {
            var result = currentRanges
            result.remove(at: idx)
            // 保证至少保留一个 cursor
            return result.isEmpty ? [NSRange(location: utf16Offset, length: 0)] : result
        }
        var result = currentRanges + [point]
        if result.count > maxCursorCount {
            result = Array(result.suffix(maxCursorCount))
        }
        return result
    }

    // MARK: - 列向添加

    /// 在 textView 中，对每个 cursor 的相同视觉列（x 像素）添加一行上方的光标。
    static func addCursorAbove(
        currentRanges: [NSRange],
        in textView: NSTextView
    ) -> [NSRange] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return currentRanges
        }

        layoutManager.ensureLayout(for: textContainer)
        var newRanges = currentRanges

        for cursorOffset in currentRanges.map({ $0.location }) {
            let clampedOffset = max(0, min(cursorOffset, (textView.string as NSString).length))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedOffset)
            guard glyphIndex < layoutManager.numberOfGlyphs else { continue }

            let charRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
            let cursorX = glyphLocation.x + textView.textContainerInset.width
            let targetY = charRect.minY - charRect.height * 0.5 + textView.textContainerInset.height

            guard targetY > textView.textContainerInset.height else { continue }

            let testPoint = NSPoint(x: cursorX, y: targetY)
            let targetGlyph = layoutManager.glyphIndex(
                for: testPoint,
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            let targetChar = layoutManager.characterIndexForGlyph(at: targetGlyph)
            let newRange = NSRange(location: targetChar, length: 0)

            if !newRanges.contains(newRange) {
                newRanges.append(newRange)
            }
        }

        if newRanges.count > maxCursorCount {
            newRanges = Array(newRanges.suffix(maxCursorCount))
        }
        return newRanges
    }

    /// 在 textView 中，对每个 cursor 的相同视觉列（x 像素）添加一行下方的光标。
    static func addCursorBelow(
        currentRanges: [NSRange],
        in textView: NSTextView
    ) -> [NSRange] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return currentRanges
        }

        layoutManager.ensureLayout(for: textContainer)
        let textLength = (textView.string as NSString).length
        var newRanges = currentRanges

        for cursorOffset in currentRanges.map({ $0.location }) {
            let clampedOffset = max(0, min(cursorOffset, textLength))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedOffset)
            guard glyphIndex < layoutManager.numberOfGlyphs else { continue }

            let charRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
            let cursorX = glyphLocation.x + textView.textContainerInset.width
            let targetY = charRect.maxY + charRect.height * 0.5 + textView.textContainerInset.height

            let testPoint = NSPoint(x: cursorX, y: targetY)
            let targetGlyph = layoutManager.glyphIndex(
                for: testPoint,
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            let targetChar = layoutManager.characterIndexForGlyph(at: targetGlyph)

            // 确保不是同一行（防止 glyphIndex 钳位到末尾）
            let targetGlyphIndex = layoutManager.glyphIndexForCharacter(at: targetChar)
            guard targetGlyphIndex < layoutManager.numberOfGlyphs else { continue }
            let targetLineRect = layoutManager.lineFragmentRect(forGlyphAt: targetGlyphIndex, effectiveRange: nil)
            guard targetLineRect.minY > charRect.minY else { continue }

            let newRange = NSRange(location: targetChar, length: 0)
            if !newRanges.contains(newRange) {
                newRanges.append(newRange)
            }
        }

        if newRanges.count > maxCursorCount {
            newRanges = Array(newRanges.suffix(maxCursorCount))
        }
        return newRanges
    }

    // MARK: - ⌘D 选词扩展

    /// 在 text 中，从 lastRange 之后搜索 searchText 的下一个 occurrence，
    /// 将其 range 追加到 currentRanges（若已存在则 done=true 不追加）。
    /// - Returns: (新 ranges, searchDidWrap: Bool)
    static func selectNextMatch(
        searchText: String,
        lastRange: NSRange,
        in text: String,
        currentRanges: [NSRange]
    ) -> (ranges: [NSRange], wrapped: Bool) {
        guard !searchText.isEmpty else { return (currentRanges, false) }
        let nsText = text as NSString
        let textLen = nsText.length

        let searchStart = min(lastRange.location + max(lastRange.length, 1), textLen)

        func find(from start: Int) -> NSRange {
            nsText.range(
                of: searchText,
                options: [],
                range: NSRange(location: start, length: textLen - start)
            )
        }

        var result = find(from: searchStart)
        var wrapped = false

        if result.location == NSNotFound {
            // wrap around from beginning
            result = find(from: 0)
            wrapped = true
        }

        guard result.location != NSNotFound else { return (currentRanges, false) }

        // 若该 range 已在 currentRanges 中，标记全部已选（done）
        if currentRanges.contains(result) { return (currentRanges, true) }

        let newRanges = currentRanges + [result]
        return (newRanges, wrapped)
    }

    // MARK: - Esc 收拢

    /// 返回仅包含 primary cursor（selectedRanges 中最后一个）的单元素数组，
    /// 光标在末尾位置（head = end of last selection）。
    static func collapseToLastCursor(from currentRanges: [NSRange]) -> [NSRange] {
        guard let last = currentRanges.last else { return currentRanges }
        // 收拢为单光标，长度归零，位于选区末尾
        return [NSRange(location: last.location + last.length, length: 0)]
    }
}
