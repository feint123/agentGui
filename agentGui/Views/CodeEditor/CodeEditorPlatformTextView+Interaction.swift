import AppKit

// MARK: - Ghost Text Acceptance

extension CodeEditorPlatformTextView {

    /// 全量接受 ghost text（对应 Tab 键）
    func acceptFullGhostText() {
        guard let snap = currentGhostText else { return }
        isAcceptingGhostText = true
        defer { isAcceptingGhostText = false }
        let insertRange = NSRange(location: snap.insertionOffset, length: 0)
        if shouldChangeText(in: insertRange, replacementString: snap.text) {
            textStorage?.replaceCharacters(in: insertRange, with: snap.text)
            didChangeText()
        }
        setSelectedRange(NSRange(location: snap.insertionOffset + snap.text.utf16.count, length: 0))
        currentGhostText = nil
    }

    /// 按词接受（对应 ⌘→）
    func acceptNextWordGhostText() {
        guard let snap = currentGhostText else { return }
        isAcceptingGhostText = true
        defer { isAcceptingGhostText = false }
        guard let wordRange = snap.nextWordRange() else {
            currentGhostText = nil
            return
        }
        let word = String(snap.text[wordRange])
        let remaining = String(snap.text[wordRange.upperBound...])

        let insertRange = NSRange(location: snap.insertionOffset, length: 0)
        if shouldChangeText(in: insertRange, replacementString: word) {
            textStorage?.replaceCharacters(in: insertRange, with: word)
            didChangeText()
        }
        let newOffset = snap.insertionOffset + word.utf16.count

        if remaining.isEmpty {
            currentGhostText = nil
        } else {
            currentGhostText = CodeEditorGhostTextSnapshot(
                generation: snap.generation,
                insertionOffset: newOffset,
                text: remaining
            )
        }
        setSelectedRange(NSRange(location: newOffset, length: 0))
    }

    /// 按行接受（对应 ⌘⏎）
    /// 规则：取 split_inclusive('\n').first()；若无换行则全量接受。
    /// 对齐 Zed editor.rs EditPredictionGranularity::Line
    func acceptNextLineGhostText() {
        guard let snap = currentGhostText else { return }
        isAcceptingGhostText = true
        defer { isAcceptingGhostText = false }

        let firstLine: String
        let remaining: String

        if let newlineRange = snap.text.range(of: "\n") {
            // 有换行：接受到换行（含换行本身）
            firstLine = String(snap.text[...newlineRange.lowerBound])
            remaining = String(snap.text[snap.text.index(after: newlineRange.lowerBound)...])
        } else {
            // 无换行：全量接受
            firstLine = snap.text
            remaining = ""
        }

        let insertRange = NSRange(location: snap.insertionOffset, length: 0)
        if shouldChangeText(in: insertRange, replacementString: firstLine) {
            textStorage?.replaceCharacters(in: insertRange, with: firstLine)
            didChangeText()
        }
        let newOffset = snap.insertionOffset + firstLine.utf16.count

        if remaining.isEmpty {
            currentGhostText = nil
        } else {
            currentGhostText = CodeEditorGhostTextSnapshot(
                generation: snap.generation,
                insertionOffset: newOffset,
                text: remaining
            )
        }
        setSelectedRange(NSRange(location: newOffset, length: 0))
    }

    // MARK: - IME Composition

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshDisplayedTextState()
        compositionStateChangeHandler?(self)
    }

    override func unmarkText() {
        let hadMarkedText = hasMarkedText()
        super.unmarkText()
        guard hadMarkedText else {
            return
        }

        refreshDisplayedTextState()
        compositionStateChangeHandler?(self)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let localPt = convert(event.locationInWindow, from: nil)

        // ⌘+Click → Go to Definition（替换旧的 Option+Click）
        if modifiers.contains(.command), !modifiers.contains(.option),
           let position = semanticPosition(at: localPt) {
            emitSemanticIntent(.requestDefinition(position))
            return
        }

        // Option+Click → 多光标 toggle（IME 期间跳过）
        if modifiers.contains(.option), !modifiers.contains(.command), !hasMarkedText() {
            guard let layoutManager, let textContainer else {
                super.mouseDown(with: event)
                return
            }
            let containerPt = NSPoint(
                x: localPt.x - textContainerInset.width,
                y: localPt.y - textContainerInset.height
            )
            let glyphIdx = layoutManager.glyphIndex(
                for: containerPt,
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            let charIdx = layoutManager.characterIndexForGlyph(at: glyphIdx)
            let currentRanges = selectedRanges.map { $0.rangeValue }
            let newRanges = CodeEditorMultiSelectionController.toggleCursor(
                at: charIdx, in: currentRanges
            )
            setSelectedRanges(
                newRanges.map { NSValue(range: $0) },
                affinity: .downstream,
                stillSelecting: false
            )
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        guard let position = semanticPosition(at: convert(event.locationInWindow, from: nil)) else {
            return
        }

        emitSemanticIntent(.requestHover(position))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        emitSemanticIntent(.cancelHover)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        // MARK: Ghost Text 键盘拦截（优先级高于 LSP completion）
        if currentGhostText != nil {
            if keyCode == 48, modifiers.isEmpty {  // Tab → 全量接受
                acceptFullGhostText()
                return
            }
            if keyCode == 124, modifiers == .command {  // ⌘→ → 按词接受
                acceptNextWordGhostText()
                return
            }
            if keyCode == 36, modifiers == .command {  // ⌘⏎ → 按行接受
                acceptNextLineGhostText()
                return
            }
            if keyCode == 53 {  // Esc → 拒绝，继续传递给多光标/面板关闭等
                clearGhostText()
                // fall through 不 return
            } else {
                // 任何其他键（非 Tab/⌘→/Esc）：清除 ghost text，让正常输入继续
                clearGhostText()
            }
        }

        // Completion panel key handling (when panel is visible, no modifiers)
        if let completionDelegate, completionDelegate.isCompletionPanelVisible, modifiers.isEmpty {
            switch keyCode {
            case 48: // Tab
                completionDelegate.acceptCompletion()
                return
            case 36: // Enter
                completionDelegate.acceptCompletion()
                return
            case 53: // Esc
                let preservedRanges = selectedRanges
                completionDelegate.dismissCompletion()
                if preservedRanges.count > 1 {
                    setSelectedRanges(preservedRanges, affinity: .downstream, stillSelecting: false)
                }
                return
            case 125: // ↓
                completionDelegate.selectNextCompletion()
                return
            case 126: // ↑
                completionDelegate.selectPrevCompletion()
                return
            default:
                break
            }
        }

        // L5: Signature help keyboard shortcuts
        if let sigDelegate = signatureHelpDelegate, sigDelegate.isSignatureHelpActive, modifiers.isEmpty {
            switch keyCode {
            case 53: // Esc
                sigDelegate.cancelSignatureHelp()
                // fall through
            case 126: // ↑ — 切换上一个重载
                if sigDelegate.isSignatureHelpPanelVisible {
                    sigDelegate.previousSignatureOverload()
                    return
                }
            case 125: // ↓ — 切换下一个重载
                if sigDelegate.isSignatureHelpPanelVisible {
                    sigDelegate.nextSignatureOverload()
                    return
                }
            default:
                break
            }
        }
        // Cmd+Ctrl+Space → 手动触发签名帮助
        if modifiers == [.command, .control], keyCode == 49 /* Space */ {
            if let sigDelegate = signatureHelpDelegate {
                let offset = selectedRange().location
                sigDelegate.invokeSignatureHelp(at: offset)
                return
            }
        }

        // ⌘⌥↑ — 添加上方光标（keyCode 126 = ↑）
        if keyCode == 126, modifiers.contains(.command), modifiers.contains(.option), !hasMarkedText() {
            let current = selectedRanges.map { $0.rangeValue }
            let newRanges = CodeEditorMultiSelectionController.addCursorAbove(
                currentRanges: current, in: self)
            setSelectedRanges(newRanges.map { NSValue(range: $0) },
                              affinity: .downstream, stillSelecting: false)
            return
        }

        // ⌘⌥↓ — 添加下方光标（keyCode 125 = ↓）
        if keyCode == 125, modifiers.contains(.command), modifiers.contains(.option), !hasMarkedText() {
            let current = selectedRanges.map { $0.rangeValue }
            let newRanges = CodeEditorMultiSelectionController.addCursorBelow(
                currentRanges: current, in: self)
            setSelectedRanges(newRanges.map { NSValue(range: $0) },
                              affinity: .downstream, stillSelecting: false)
            return
        }

        // ⌘D — 选中下一个匹配词（keyCode 2 = D）
        if keyCode == 2, modifiers.contains(.command),
           !modifiers.contains(.option), !modifiers.contains(.shift), !hasMarkedText() {
            selectNextWordMatch()
            return
        }

        // Esc — 多光标时收拢为最后一个光标
        if keyCode == 53 {
            let current = selectedRanges.map { $0.rangeValue }
            if current.count > 1 {
                let collapsed = CodeEditorMultiSelectionController.collapseToLastCursor(from: current)
                setSelectedRanges(collapsed.map { NSValue(range: $0) },
                                  affinity: .downstream, stillSelecting: false)
                return
            }
            // fall through to performKeyEquivalent for find bar dismiss etc.
        }

        // F12 / keyCode 111 — Go to Definition / References
        if keyCode == 111 {
            if modifiers.contains(.shift),
               let position = semanticPositionForSelection() {
                emitSemanticIntent(.requestReferences(position))
                return
            }

            if let position = semanticPositionForSelection() {
                emitSemanticIntent(.requestDefinition(position))
                return
            }
        }

        super.keyDown(with: event)
    }

    private func selectNextWordMatch() {
        let current = selectedRanges.map { $0.rangeValue }
        guard let lastRange = current.last else { return }

        var searchText: String
        if lastRange.length > 0 {
            searchText = (string as NSString).substring(with: lastRange)
        } else {
            // zero-length cursor → 扩展为当前词
            let nsStr = string as NSString
            let textLen = nsStr.length

            let backwardRange = NSRange(location: 0, length: lastRange.location)
            let wordStartRange = nsStr.rangeOfCharacter(
                from: CharacterSet.alphanumerics.inverted,
                options: .backwards,
                range: backwardRange
            )
            let start = wordStartRange.location == NSNotFound
                ? 0
                : wordStartRange.location + wordStartRange.length

            let forwardRange = NSRange(location: lastRange.location, length: textLen - lastRange.location)
            let wordEndRange = nsStr.rangeOfCharacter(
                from: CharacterSet.alphanumerics.inverted,
                options: [],
                range: forwardRange
            )
            let end = wordEndRange.location == NSNotFound ? textLen : wordEndRange.location

            guard end > start else { return }
            let expandedRange = NSRange(location: start, length: end - start)

            // 先扩展当前光标的 range 到整词
            let updated = Array(current.dropLast()) + [expandedRange]
            setSelectedRanges(updated.map { NSValue(range: $0) },
                              affinity: .downstream, stillSelecting: false)
            // 递归调用一次去选下一个
            selectNextWordMatch()
            return
        }

        let (newRanges, _) = CodeEditorMultiSelectionController.selectNextMatch(
            searchText: searchText,
            lastRange: lastRange,
            in: string,
            currentRanges: current
        )
        if newRanges.count > current.count {
            setSelectedRanges(newRanges.map { NSValue(range: $0) },
                              affinity: .downstream, stillSelecting: false)
            scrollRangeToVisible(newRanges[newRanges.count - 1])
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" {
            findIntentHandler?(.present)
            return true
        }

        if event.keyCode == 53 {
            findIntentHandler?(.dismiss)
            return true
        }

        if event.keyCode == 36 {
            findIntentHandler?(modifiers.contains(.shift) ? .previousMatch : .nextMatch)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
