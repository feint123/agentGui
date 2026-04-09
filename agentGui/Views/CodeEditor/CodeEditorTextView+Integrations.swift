import AppKit

// MARK: - Runtime Integrations

extension CodeEditorTextView.Coordinator {

    func updateAgentDiff(for textView: CodeEditorPlatformTextView) {
        textView.agentChangeDiffByLine = parent.agentChangeDiffByLine
    }

    func syncRuntimeIntegrations(for textView: CodeEditorPlatformTextView) {
        if parent.isCompletionEnabled {
            installCompletion(for: textView)
        } else {
            uninstallCompletion(for: textView)
        }

        if parent.isInlayHintsEnabled, parent.lspCoordinator != nil {
            installInlayHints(for: textView)
        } else {
            uninstallInlayHints(for: textView)
        }

        if parent.isSignatureHelpEnabled {
            installSignatureHelp(for: textView)
        } else {
            uninstallSignatureHelp(for: textView)
        }

        if parent.isGhostTextEnabled, let client = parent.ghostTextClient {
            installGhostText(client: client, modelId: parent.ghostTextModelId, textView: textView)
        } else {
            uninstallGhostText(textView: textView)
        }
    }

    // MARK: - Completion Integration

    /// 初始化代码补全面板和触发器，连接 LSP coordinator 回调。
    func installCompletion(for textView: CodeEditorPlatformTextView) {
        if completionPanel != nil {
            textView.completionDelegate = self
            return
        }

        let panel = CodeEditorCompletionPanel()
        completionPanel = panel
        textView.completionDelegate = self

        // 面板接受时插入补全
        panel.onAccept = { [weak self, weak textView] item in
            guard let self, let textView else { return }
            self.acceptCompletion(item: item, in: textView)
        }
        panel.onDismiss = { [weak self] in
            self?.completionTrigger.dismiss()
        }

        // 触发器 → LSP coordinator 桥接（运行时动态读取，避免 makeNSView 时 coordinator 尚未建立的时序问题）
        completionTrigger.requestCompletion = { [weak self] ctx, callback in
            self?.parent.lspCoordinator?.requestCompletion(context: ctx, onResult: callback)
        }
        completionTrigger.cancelRequest = { [weak self] in
            self?.parent.lspCoordinator?.cancelCompletion()
        }

        // 面板刷新
        completionTrigger.onSessionChange = { [weak self, weak textView, weak panel] session in
            guard let textView, let panel else { return }
            if let session, !session.isLoading, !session.items.isEmpty {
                panel.update(session: session)
                let cursorRect = textView.cursorRect
                if let window = textView.window {
                    // 传递 window 坐标系的矩形，由 panel.positionPanel 统一执行一次 screen 转换
                    let windowRect = textView.convert(cursorRect, to: nil)
                    panel.show(anchoredBelow: windowRect, in: window)
                }
            } else {
                panel.hide()
            }
            _ = self  // capture self for lifetime
        }
    }

    func uninstallCompletion(for textView: CodeEditorPlatformTextView) {
        textView.completionDelegate = nil
        completionPanel?.hide()
        completionPanel?.onAccept = nil
        completionPanel?.onDismiss = nil
        completionPanel = nil
        completionTrigger.dismiss()
    }

    fileprivate func acceptCompletion(item: CodeEditorCompletionItem, in textView: CodeEditorPlatformTextView) {
        let session = completionTrigger.currentSession
        let prefixWord = session?.prefixWord ?? ""
        let cursorOffset = textView.selectedRange().location
        let currentText = textView.string

        let replaceRange = NSRange(
            location: max(0, cursorOffset - prefixWord.utf16.count),
            length: prefixWord.utf16.count
        )
        guard replaceRange.location + replaceRange.length <= (currentText as NSString).length else {
            return
        }

        let insertionResult = CodeEditorCompletionInserter.apply(
            item: item,
            to: currentText,
            cursorOffset: cursorOffset,
            prefixWord: prefixWord
        )

        // 用简单字符串替换，让 commitDisplayedText 处理 undo 栈
        if textView.shouldChangeText(in: replaceRange, replacementString: item.insertText) {
            textView.textStorage?.replaceCharacters(in: replaceRange, with: item.insertText)
            textView.didChangeText()
        }

        let newCursorOffset = insertionResult.newCursorOffset
        textView.setSelectedRange(NSRange(location: newCursorOffset, length: 0))
        completionTrigger.confirmed()
    }

    // MARK: - Signature Help Integration

    func installSignatureHelp(for textView: CodeEditorPlatformTextView) {
        if signatureHelpPanel != nil {
            textView.signatureHelpDelegate = self
            return
        }

        let panel = CodeEditorSignatureHelpPanel()
        signatureHelpPanel = panel
        textView.signatureHelpDelegate = self

        panel.onNext = { [weak self] in self?.signatureHelpTrigger.next() }
        panel.onPrevious = { [weak self] in self?.signatureHelpTrigger.previous() }

        // Trigger → Coordinator → LSPClient 桥接
        signatureHelpTrigger.requestSignatureHelp = { [weak self] context, callback in
            guard let self,
                  let coord = self.parent.lspCoordinator else {
                callback(nil)
                return
            }
            // 使用当前光标位置
            guard let tv = textView as? CodeEditorPlatformTextView else {
                callback(nil)
                return
            }
            let offset = tv.selectedRange().location
            let position = tv.codePosition(for: offset)
            coord.requestSignatureHelp(
                context: context,
                line: position.line,
                character: position.character,
                onResult: callback
            )
        }

        // 状态变化 → 显示或隐藏 panel
        signatureHelpTrigger.onSessionChange = { [weak self, weak textView, weak panel] help in
            guard let panel else { return }
            if let help {
                panel.update(help: help)
                if let tv = textView, let window = tv.window {
                    let cursorRect = tv.convert(tv.cursorRect, to: nil)
                    panel.show(anchoredBelow: cursorRect, in: window)
                }
            } else {
                panel.hide()
            }
            _ = self
        }
    }

    func uninstallSignatureHelp(for textView: CodeEditorPlatformTextView) {
        textView.signatureHelpDelegate = nil
        signatureHelpPanel?.hide()
        signatureHelpPanel?.onNext = nil
        signatureHelpPanel?.onPrevious = nil
        signatureHelpPanel = nil
        signatureHelpTrigger.cancel()
    }

    // MARK: - Ghost Text Integration

    func installGhostText(
        client: any GhostTextClientProtocol,
        modelId: String,
        textView: CodeEditorPlatformTextView
    ) {
        if ghostTextService != nil { return }  // 已安装，跳过
        let service = CodeEditorGhostTextService(client: client, modelId: modelId)
        ghostTextService = service

        let trigger = CodeEditorGhostTextTrigger(debounceMs: 500)
        trigger.onRequestGhostText = { [weak self, weak textView] gen, ctxProvider in
            guard let self, let textView else { return }
            self.handleGhostTextRequest(generation: gen, contextProvider: ctxProvider, textView: textView)
        }
        ghostTextTrigger = trigger
    }

    func uninstallGhostText(textView: CodeEditorPlatformTextView) {
        ghostTextService?.cancel()
        ghostTextService = nil
        ghostTextTrigger?.cancel()
        ghostTextTrigger = nil
        textView.clearGhostText()
    }

    func handleGhostTextRequest(
        generation: Int,
        contextProvider: CodeEditorGhostTextTrigger.ContextProvider,
        textView: CodeEditorPlatformTextView
    ) {
        guard let service = ghostTextService,
              let context = contextProvider() else { return }

        let insertionOffset = textView.selectedRange().location

        service.request(
            prefix: context.prefix,
            suffix: context.suffix,
            language: context.language,
            generation: generation,
            onFirstLine: { [weak textView] firstLine in
                Task { @MainActor [weak textView] in
                    // 代际感知保护：若已有更新代际的 ghost text，不覆盖（防止旧请求覆盖新结果）
                    if let existing = textView?.currentGhostText, existing.generation > generation {
                        return
                    }
                    textView?.currentGhostText = CodeEditorGhostTextSnapshot(
                        generation: generation,
                        insertionOffset: insertionOffset,
                        text: firstLine
                    )
                }
            },
            onComplete: { [weak textView] fullText in
                Task { @MainActor [weak textView] in
                    textView?.currentGhostText = CodeEditorGhostTextSnapshot(
                        generation: generation,
                        insertionOffset: insertionOffset,
                        text: fullText
                    )
                }
            },
            onCancel: { [weak textView] in
                Task { @MainActor [weak textView] in
                    textView?.clearGhostText()
                }
            }
        )
    }

    // MARK: - Inlay Hints Integration

    func installInlayHints(for textView: CodeEditorPlatformTextView) {
        guard let coordinator = parent.lspCoordinator else {
            uninstallInlayHints(for: textView)
            return
        }

        if installedInlayHintsCoordinator === coordinator {
            return
        }

        installedInlayHintsCoordinator?.onInlayHintResult = nil
        coordinator.onInlayHintResult = { [weak textView] snapshot in
            textView?.currentInlayHintSnapshot = snapshot
        }
        installedInlayHintsCoordinator = coordinator
    }

    func uninstallInlayHints(for textView: CodeEditorPlatformTextView) {
        installedInlayHintsCoordinator?.cancelInlayHintRequest()
        installedInlayHintsCoordinator?.onInlayHintResult = nil
        installedInlayHintsCoordinator = nil
        lastScheduledInlayHintRange = nil
        lastScheduledInlayHintVersion = nil
        textView.currentInlayHintSnapshot = .empty
    }

    func scheduleInlayHintRequest(for textView: CodeEditorPlatformTextView) {
        guard parent.isInlayHintsEnabled else { return }
        guard !textView.hasMarkedText() else { return }

        let range = visibleLineRange(for: textView) ?? fullDocumentLineRange()
        let version = parent.document.version

        if lastScheduledInlayHintRange == range,
           lastScheduledInlayHintVersion == version {
            return
        }
        lastScheduledInlayHintRange = range
        lastScheduledInlayHintVersion = version

        parent.lspCoordinator?.scheduleInlayHintRequest(
            visibleLineRange: range,
            documentVersion: version
        )
    }
}
