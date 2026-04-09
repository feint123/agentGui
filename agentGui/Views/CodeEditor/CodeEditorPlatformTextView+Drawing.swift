import AppKit

// MARK: - Drawing

extension CodeEditorPlatformTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        // F24：Agent 变更行内联背景高亮（底层，在其他叠层之前）
        drawAgentDiffBackground(in: rect)

        // 为所有光标行绘制高亮背景
        for line in highlightedLineNumbers {
            if let lineRect = backgroundRect(forLine: line), lineRect.intersects(rect) {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.10).setFill()
                lineRect.fill()
            }
        }

        // 绘制缩进参考线（在当前行高亮之上，参考线可见）
        drawIndentGuides(in: rect)
        // 绘制 LSP inlay hints（叠层，不修改 TextStorage）
        drawInlayHints(in: rect)
        // 绘制 AI ghost text（内联建议，不修改 TextStorage）
        if let ghostText = currentGhostText {
            drawGhostText(ghostText, in: rect)
        }
    }

    // MARK: - Agent Diff Background（F24）

    func drawAgentDiffBackground(in rect: NSRect) {
        guard !agentChangeDiffByLine.isEmpty,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let textStorage = self.textStorage else { return }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        guard visibleGlyphRange.length > 0 else { return }
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        var logicalLine = 1
        let fullString = textStorage.string as NSString
        let nsRange = NSRange(location: 0, length: textStorage.length)

        fullString.enumerateSubstrings(in: nsRange, options: [.byLines, .substringNotRequired]) { _, _, enclosingRange, _ in
            defer { logicalLine += 1 }
            guard let kind = self.agentChangeDiffByLine[logicalLine] else { return }

            let intersect = NSIntersectionRange(enclosingRange, visibleCharRange)
            guard intersect.length > 0 || enclosingRange.location == visibleCharRange.location else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: enclosingRange, actualCharacterRange: nil)
            var lineRect: NSRect = .zero
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
                if lineRect == .zero {
                    lineRect = fragmentRect
                } else {
                    lineRect = lineRect.union(fragmentRect)
                }
            }
            guard lineRect != .zero else { return }

            lineRect.origin.x = 0
            lineRect.size.width = self.bounds.width
            guard lineRect.intersects(rect) else { return }

            let color: NSColor
            switch kind {
            case .added:
                color = NSColor.systemPurple.withAlphaComponent(0.08)
            case .modified:
                color = NSColor.systemCyan.withAlphaComponent(0.08)
            case .deleted:
                return
            }
            color.setFill()
            lineRect.fill()
        }
    }

    // MARK: - Inlay Hints

    func drawInlayHints(in rect: NSRect) {
        // IME 期间不绘制（避免视觉混乱）
        guard !hasMarkedText() else { return }
        guard let layoutManager,
              let textContainer else { return }

        let snapshot = currentInlayHintSnapshot
        guard snapshot.documentVersion == currentDocumentVersion,
              !snapshot.hintsByLine.isEmpty else { return }

        guard let editorFont = self.font else { return }
        let hintFontSize = max(editorFont.pointSize - 1, 8)
        let hintFont = NSFont.monospacedSystemFont(ofSize: hintFontSize, weight: .light)

        for (line, hints) in snapshot.hintsByLine {
            for hint in hints {
                drawSingleInlayHint(
                    hint,
                    line: line,
                    hintFont: hintFont,
                    layoutManager: layoutManager,
                    textContainer: textContainer,
                    clipRect: rect
                )
            }
        }
    }

    func drawSingleInlayHint(
        _ hint: CodeEditorInlayHint,
        line: Int,
        hintFont: NSFont,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        clipRect: NSRect
    ) {
        let charOffset = displayedLineIndex.utf16Offset(line: line, column: max(1, hint.character))
        guard charOffset >= 0,
              charOffset <= (textStorage?.length ?? 0) else { return }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charOffset)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return }

        var effectiveGlyphRange = NSRange()
        let lineFragmentRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &effectiveGlyphRange
        )
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let x = lineFragmentRect.minX + textContainerInset.width + glyphLocation.x
        let y = lineFragmentRect.minY + textContainerInset.height

        let estimatedWidth: CGFloat = CGFloat(hint.label.count) * (hintFont.pointSize * 0.6) + 8
        let hintRect = NSRect(x: x, y: y, width: estimatedWidth, height: lineFragmentRect.height)
        guard clipRect.intersects(hintRect) else { return }

        var displayLabel = ""
        if hint.paddingLeft  { displayLabel += "\u{200A}" }
        displayLabel += hint.label
        if hint.paddingRight { displayLabel += "\u{200A}" }

        let foregroundColor: NSColor
        let backgroundColor: NSColor
        switch hint.kind {
        case .type:
            foregroundColor = NSColor.systemPurple.withAlphaComponent(0.75)
            backgroundColor = NSColor.systemPurple.withAlphaComponent(0.10)
        case .parameter:
            foregroundColor = NSColor.systemBlue.withAlphaComponent(0.75)
            backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10)
        case .unknown:
            foregroundColor = NSColor.tertiaryLabelColor
            backgroundColor = NSColor.clear
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: hintFont,
            .foregroundColor: foregroundColor,
        ]
        let str = NSAttributedString(string: displayLabel, attributes: attributes)
        let strSize = str.size()

        let bgRect = NSRect(
            x: x - 2.0,
            y: y + (lineFragmentRect.height - strSize.height) / 2 - 1,
            width: strSize.width + 4.0,
            height: strSize.height + 2.0
        )
        if hint.kind != .unknown {
            let path = NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3)
            backgroundColor.setFill()
            path.fill()
        }

        let drawY = y + (lineFragmentRect.height - strSize.height) / 2
        str.draw(at: NSPoint(x: x, y: drawY))
    }

    // MARK: - Ghost Text Rendering

    func drawGhostText(_ snapshot: CodeEditorGhostTextSnapshot, in rect: NSRect) {
        // IME 期间不绘制（避免 composition 中出现乱字）
        guard !hasMarkedText() else { return }
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let font = self.font else { return }

        let insertionPoint = snapshot.insertionOffset
        let textLen = textStorage?.length ?? 0
        guard insertionPoint <= textLen else { return }

        // 找光标插入点对应的 glyph
        let glyphCount = layoutManager.numberOfGlyphs
        let glyphIdx: Int
        if glyphCount == 0 {
            glyphIdx = 0
        } else {
            glyphIdx = min(layoutManager.glyphIndexForCharacter(at: insertionPoint), glyphCount - 1)
        }

        // 光标矩形（boundingRect for empty range = insertion point position）
        let cursorGlyphRange = NSRange(location: glyphIdx, length: 0)
        let cursorRect = layoutManager.boundingRect(
            forGlyphRange: cursorGlyphRange,
            in: textContainer
        ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)

        let lineHeight = layoutManager.defaultLineHeight(for: font)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for displayLine in snapshot.displayLines {
            let text = displayLine.text
            guard !text.isEmpty else { continue }

            let yOffset = cursorRect.minY + CGFloat(displayLine.lineOffset) * lineHeight
            // 只绘制与 dirtyRect 有交集的行
            let estimatedLineRect = NSRect(x: 0, y: yOffset, width: bounds.width, height: lineHeight)
            guard rect.intersects(estimatedLineRect) else { continue }

            let drawX: CGFloat
            if displayLine.lineOffset == 0 {
                // 插入行：在光标右侧绘制
                drawX = cursorRect.maxX
            } else {
                // 后续行：与光标列对齐（与光标行首字符同列）
                drawX = cursorRect.minX
            }

            (text as NSString).draw(at: NSPoint(x: drawX, y: yOffset), withAttributes: attrs)
        }
    }

    // MARK: - Indent Guide Drawing

    static let indentGuideInactiveColor = NSColor.separatorColor.withAlphaComponent(0.35)
    static let indentGuideActiveColor   = NSColor.separatorColor.withAlphaComponent(0.70)

    func drawIndentGuides(in rect: NSRect) {
        let config = indentGuideConfig
        guard config.indentWidth > 0, !hasMarkedText() else { return }

        // 1. 取可见行 metrics
        let metrics = visibleLineMetrics(in: rect)
        guard !metrics.isEmpty else { return }

        // 2. 字符宽度：用等宽字体测量单个空格
        guard let font else { return }
        let charWidth = measureCharWidth(font: font)
        guard charWidth > 0 else { return }

        let insetX = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        let nsStr = string as NSString

        // 3. 收集可见行的行首文本用于扫描层级（仅取前 200 个字符，性能保护）
        let lineTexts: [String] = metrics.map { metric in
            let lineRange = displayedUTF16LineRange(forLine: metric.line)
            let safeLength = min(200, lineRange.length)
            guard lineRange.location != NSNotFound,
                  safeLength >= 0,
                  lineRange.location + safeLength <= nsStr.length else { return "" }
            return nsStr.substring(with: NSRange(location: lineRange.location, length: safeLength))
        }

        let levels = CodeEditorIndentGuideScanner.computeLevels(
            forLines: lineTexts,
            indentWidth: config.indentWidth,
            useTabs: config.useTabs
        )

        // 4. 计算 active indent guide 范围
        let activeGuideRange = computeActiveIndentGuideRange(
            metrics: metrics,
            levels: levels
        )

        // 5. 绘制
        let scaleFactor = window?.backingScaleFactor ?? 1.0
        let lineWidth: CGFloat = 1.0 / max(1.0, scaleFactor)

        NSGraphicsContext.saveGraphicsState()
        for (i, metric) in metrics.enumerated() {
            guard i < levels.count else { break }
            let levelInfo = levels[i]
            guard levelInfo.level > 0 else { continue }
            guard metric.rect.intersects(rect) else { continue }

            for depthIdx in 0 ..< levelInfo.level {
                let xPos = insetX + CGFloat(depthIdx) * CGFloat(config.indentWidth) * charWidth
                let guideRect = NSRect(
                    x: xPos,
                    y: metric.rect.minY,
                    width: lineWidth,
                    height: metric.rect.height
                )

                if guideRect.maxX < rect.minX || guideRect.minX > rect.maxX { continue }

                let isActive: Bool
                if let activeRange = activeGuideRange,
                   activeRange.lineRange.contains(metric.line),
                   depthIdx == activeRange.depth {
                    isActive = true
                } else {
                    isActive = false
                }

                let color = isActive
                    ? CodeEditorPlatformTextView.indentGuideActiveColor
                    : CodeEditorPlatformTextView.indentGuideInactiveColor
                color.setFill()
                guideRect.fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 测量等宽字体的单个字符宽度。
    func measureCharWidth(font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (" " as NSString).size(withAttributes: attrs)
        return size.width
    }

    struct IndentGuideActiveRange {
        let lineRange: ClosedRange<Int>  // 1-indexed 逻辑行
        let depth: Int                    // 0-indexed depth（对应 indentLevel - 1）
    }

    func computeActiveIndentGuideRange(
        metrics: [CodeEditorVisibleLineMetric],
        levels: [CodeEditorIndentGuideLevel]
    ) -> IndentGuideActiveRange? {
        guard !hasMarkedText() else { return nil }

        // 光标当前行（1-indexed）
        let cursorLine = highlightedLineNumber ?? 1

        // 找光标行在可见 metrics 中的 index
        guard let cursorIdx = metrics.firstIndex(where: { $0.line == cursorLine }),
              cursorIdx < levels.count else {
            return nil
        }

        let cursorLevel = levels[cursorIdx].level
        guard cursorLevel > 0 else { return nil }

        // active guide：光标行所在缩进块（最深级）
        // targetDepth 是 0-indexed，画在 cursorLevel 级的列
        let targetDepth = cursorLevel - 1

        var startLine = cursorLine
        var endLine   = cursorLine

        // 向上扩展：找到所有 level >= cursorLevel 的连续行
        for i in stride(from: cursorIdx - 1, through: 0, by: -1) {
            let lvl = levels[i]
            if !lvl.isBlankLine && lvl.level < cursorLevel { break }
            startLine = metrics[i].line
        }

        // 向下扩展
        let upperBound = min(metrics.count, levels.count)
        for i in (cursorIdx + 1) ..< upperBound {
            let lvl = levels[i]
            if !lvl.isBlankLine && lvl.level < cursorLevel { break }
            endLine = metrics[i].line
        }

        return IndentGuideActiveRange(lineRange: startLine...endLine, depth: targetDepth)
    }
}
