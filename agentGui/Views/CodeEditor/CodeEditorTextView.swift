import AppKit
import SwiftUI

struct CodeEditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var document: CodeEditorDocument
    var language: String? = nil
    var focusRequest: UUID? = nil
    var revealRequest: CodeEditorRevealRequest? = nil
    var hoverPresentation: CodeEditorHoverPresentation? = nil
    var onSelectionChange: ((EditorSelectionSnapshot?) -> Void)? = nil
    var onCursorLocationChange: ((CodeEditorTextLocation) -> Void)? = nil
    var onVisibleLineRangeChange: ((ClosedRange<Int>) -> Void)? = nil
    var onSemanticIntent: ((CodeEditorSemanticIntent) -> Void)? = nil
    var onFindIntent: ((CodeEditorFindIntent) -> Void)? = nil
    var decorations: CodeEditorDecorationSnapshot = .empty(version: 0, lineRange: 1...1)
    var diagnosticsByLine: [Int: CodeEditorLineDiagnosticSummary] = [:]
    var gitDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:]
    var onGutterLaneHit: ((CodeEditorGutterHitResult) -> Void)? = nil
    var onChangeSet: ((EditorChangeSet) -> Void)? = nil
    var highlighter: any CodeSyntaxHighlighting = CodeSyntaxHighlightingService.shared
    var highlightDebounceNanoseconds: UInt64 = 75_000_000
    var highlightExecutionDelayNanoseconds: UInt64 = 0
    var isBracketPairColorizationEnabled: Bool = false
    var indentationStatus: CodeEditorIndentationStatus = CodeEditorIndentationStatus(kind: .unknown, width: 0)
    var lspCoordinator: CodeEditorLSPCoordinator? = nil
    var isCompletionEnabled: Bool = false
    var isInlayHintsEnabled: Bool = false
    var isSignatureHelpEnabled: Bool = false
    var isGhostTextEnabled: Bool = false
    var ghostTextClient: (any GhostTextClientProtocol)?
    var ghostTextModelId: String = "claude-haiku-4-5"

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CodeEditorViewportContainerView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = CodeEditorPlatformTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.refreshDisplayedTextState()
        textView.currentDocumentVersion = document.version
        textView.setAccessibilityIdentifier("codeEditor.textView")
        textView.highlightedLineNumber = document.location(ofUTF16Offset: document.selectedRange.location).line
        textView.semanticIntentHandler = onSemanticIntent
        textView.findIntentHandler = onFindIntent
        textView.latestDecorationSnapshot = decorations
        textView.updateHoverPresentation(hoverPresentation)
        textView.compositionStateChangeHandler = { [weak coordinator = context.coordinator] textView in
            coordinator?.handleCompositionStateChange(in: textView)
        }

        scrollView.documentView = textView
        let containerView = CodeEditorViewportContainerView(scrollView: scrollView, textView: textView)
        context.coordinator.installGutter(for: containerView)
        context.coordinator.installSelectionObserver(for: textView)
        context.coordinator.installViewportObserver(for: scrollView, textView: textView)
        context.coordinator.schedulePostUpdateRefresh(for: textView, dirtyLineRange: nil)
        context.coordinator.syncRuntimeIntegrations(for: textView)
        return containerView
    }

    func updateNSView(_ containerView: CodeEditorViewportContainerView, context: Context) {
        let scrollView = containerView.scrollView
        let textView = containerView.textView
        context.coordinator.parent = self
        context.coordinator.installGutter(for: containerView)
        textView.semanticIntentHandler = onSemanticIntent
        textView.findIntentHandler = onFindIntent
        textView.currentDocumentVersion = document.version
        textView.latestDecorationSnapshot = decorations
        textView.updateHoverPresentation(hoverPresentation)

        var dirtyLineRange: ClosedRange<Int>?
        if !textView.hasMarkedText(), textView.string != text {
            let selectedRange = clampedRange(document.selectedRange, for: text)
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.string = text
            textView.refreshDisplayedTextState()
            textView.setSelectedRange(selectedRange)
            context.coordinator.isApplyingProgrammaticUpdate = false
            textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: selectedRange.location).line
            dirtyLineRange = context.coordinator.fullDocumentLineRange()
        }

        textView.highlightedLineNumber = textView.displayedLocation(ofUTF16Offset: textView.selectedRange().location).line
        context.coordinator.updateGutterState(for: textView)
        context.coordinator.updateAgentDiff(for: textView)
        context.coordinator.applyCachedHighlightPresentation(to: textView)
        context.coordinator.syncRuntimeIntegrations(for: textView)

        (textView as? CodeEditorPlatformTextView)?.indentGuideConfig =
            CodeEditorIndentGuideConfig(from: indentationStatus)

        context.coordinator.schedulePostUpdateRefresh(for: textView, dirtyLineRange: dirtyLineRange)

        if !isInlayHintsEnabled {
            textView.currentInlayHintSnapshot = .empty
        }

        if let focusRequest,
           context.coordinator.lastAppliedFocusRequest != focusRequest {
            context.coordinator.lastAppliedFocusRequest = focusRequest
            context.coordinator.applyFocus(to: textView)
        }

        if let revealRequest,
           context.coordinator.lastAppliedRevealRequestID != revealRequest.id {
            context.coordinator.lastAppliedRevealRequestID = revealRequest.id
            context.coordinator.applyRevealRequest(revealRequest, to: textView)
        }
    }

    private func clampedRange(_ range: NSRange, for text: String) -> NSRange {
        let length = text.utf16.count
        let location = max(0, min(range.location, length))
        let safeLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }
}

extension CodeEditorTextView {
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorTextView
        var isApplyingProgrammaticUpdate = false
        var lastAppliedFocusRequest: UUID?
        var lastAppliedRevealRequestID: UUID?
        private var selectionObserver: NSObjectProtocol?
        private var viewportObserver: NSObjectProtocol?
        private var pendingEdit: PendingEdit?
        private var isMultiCursorEdit = false
        private let highlightScheduler = CodeEditorHighlightScheduler()
        private let highlightPipeline = CodeEditorHighlightPipeline()
        private var lastScheduledHighlightVersion: Int?
        private var lastScheduledVisibleLineRange: ClosedRange<Int>?
        private var lastPublishedVisibleLineRange: ClosedRange<Int>?
        private var pendingPostUpdateRefreshID: UUID?

        // MARK: - Completion
        private let completionTrigger = CodeEditorCompletionTrigger()
        private var completionPanel: CodeEditorCompletionPanel?
        private var isInIMEComposition = false

        // MARK: - Signature Help
        private let signatureHelpTrigger = CodeEditorSignatureHelpTrigger()
        private var signatureHelpPanel: CodeEditorSignatureHelpPanel?

        // MARK: - Inlay Hints
        private weak var installedInlayHintsCoordinator: CodeEditorLSPCoordinator?
        private var lastScheduledInlayHintRange: ClosedRange<Int>?
        private var lastScheduledInlayHintVersion: Int?

        // MARK: - Ghost Text
        private var ghostTextTrigger: CodeEditorGhostTextTrigger?
        private var ghostTextService: CodeEditorGhostTextService?

        init(_ parent: CodeEditorTextView) {
            self.parent = parent
        }

        deinit {
            let highlightScheduler = self.highlightScheduler
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            Task {
                await highlightScheduler.cancel()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
                return true
            }

            (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

            pendingEdit = PendingEdit(
                replacedRange: affectedCharRange,
                insertedText: replacementString ?? ""
            )
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextInRanges affectedRanges: [NSValue],
            replacementStrings: [String]?
        ) -> Bool {
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
                return true
            }

            (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)

            if affectedRanges.count > 1 {
                // 多光标编辑：标记回退到全文差分路径
                isMultiCursorEdit = true
                pendingEdit = nil
            } else {
                isMultiCursorEdit = false
                if let range = affectedRanges.first?.rangeValue {
                    pendingEdit = PendingEdit(
                        replacedRange: range,
                        insertedText: replacementStrings?.first ?? ""
                    )
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeEditorPlatformTextView else { return }
            guard !isApplyingProgrammaticUpdate else {
                pendingEdit = nil
                isMultiCursorEdit = false
                return
            }

            textView.refreshDisplayedTextState()

            if textView.hasMarkedText() {
                publishSelection(for: textView)
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                cancelHighlight()
                return
            }

            commitDisplayedText(from: textView, preferPendingEdit: true)

            // F19: Completion trigger (after user edit, not IME)
            guard !isInIMEComposition, !textView.hasMarkedText() else { return }
            if parent.isCompletionEnabled,
               let lspCoordinator = parent.lspCoordinator,
               let caps = lspCoordinator.capabilities,
               caps.supportsCompletion {
                let cursorOffset = textView.selectedRange().location
                let prefixWord = textView.prefixWordBeforeCursor()
                let lastTyped = textView.lastTypedCharacter ?? ""
                completionTrigger.handleTyping(
                    char: lastTyped,
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    triggerCharacters: caps.completionTriggerCharacters
                )
            }

            // L5: Signature help trigger
            if parent.isSignatureHelpEnabled,
               let lspCoordinator = parent.lspCoordinator,
               let caps = lspCoordinator.capabilities,
               caps.supportsSignatureHelp {
                let cursorOffset = textView.selectedRange().location
                let lastTyped = textView.lastTypedCharacter ?? ""
                signatureHelpTrigger.handleTyping(
                    char: lastTyped,
                    cursorOffset: cursorOffset,
                    triggerCharacters: caps.signatureHelpTriggerCharacters,
                    retriggerCharacters: caps.signatureHelpRetriggerCharacters
                )
            }

            // F23: Ghost text trigger（LSP 补全面板未显示时才触发）
            let completionPanelVisible = completionPanel?.panel.isVisible ?? false
            ghostTextTrigger?.handleChange(
                isIMEActive: textView.hasMarkedText(),
                isGhostTextEnabled: parent.isGhostTextEnabled && !completionPanelVisible,
                contextProvider: { [weak textView] in
                    textView?.extractGhostTextContext(language: self.parent.language)
                }
            )
        }

        func handleCompositionStateChange(in textView: CodeEditorPlatformTextView) {
            guard !isApplyingProgrammaticUpdate else {
                return
            }

            publishSelection(for: textView)
            publishVisibleLineRange(for: textView)
            updateGutterState(for: textView)

            // Track IME composition state for completion suppression
            isInIMEComposition = textView.hasMarkedText()
            if isInIMEComposition {
                completionTrigger.dismiss()
            }

            if textView.hasMarkedText() {
                // IME 期间清除括号高亮，避免视觉混乱
                textView.applyBracketMatchHighlight(nil)
                cancelHighlight()
                return
            }

            textView.emitSemanticIntent(.cancelHover)

            guard textView.string != parent.document.text else {
                scheduleHighlight(for: textView, dirtyLineRange: nil)
                return
            }

            commitDisplayedText(from: textView, preferPendingEdit: false)
        }

        func installSelectionObserver(for textView: NSTextView) {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }

            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: nil
            ) { [weak self, weak textView] _ in
                guard let self, let textView, !self.isApplyingProgrammaticUpdate else { return }
                (textView as? CodeEditorPlatformTextView)?.emitSemanticIntent(.cancelHover)
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView, !self.isApplyingProgrammaticUpdate else { return }
                    self.publishSelection(for: textView)
                }
            }
        }

        func installGutter(for containerView: CodeEditorViewportContainerView) {
            containerView.gutterView.onRequiredWidthChange = { [weak containerView] in
                containerView?.needsLayout = true
            }
            containerView.gutterView.onGutterLaneHit = { [weak self] hitResult in
                self?.parent.onGutterLaneHit?(hitResult)
            }
        }

        func installViewportObserver(for scrollView: NSScrollView, textView: CodeEditorPlatformTextView) {
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }

            scrollView.contentView.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                textView.emitSemanticIntent(.cancelHover)
                self.scheduleHighlight(for: textView, dirtyLineRange: nil)
            }
        }

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

        private func acceptCompletion(item: CodeEditorCompletionItem, in textView: CodeEditorPlatformTextView) {
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

        func publishSelection(for textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            let cursorLocation: CodeEditorTextLocation
            if let textView = textView as? CodeEditorPlatformTextView {
                cursorLocation = textView.displayedLocation(ofUTF16Offset: selectedRange.location)
            } else {
                cursorLocation = parent.document.location(ofUTF16Offset: selectedRange.location)
            }
            let snapshot = selectionSnapshot(for: textView, text: textView.string, range: selectedRange)
            parent.onSelectionChange?(snapshot)
            parent.onCursorLocationChange?(cursorLocation)

            // 多光标行高亮
            if let platformTextView = textView as? CodeEditorPlatformTextView {
                let cursorLines = Set(
                    platformTextView.selectedRanges.map { $0.rangeValue }.map { range -> Int in
                        platformTextView.displayedLocation(ofUTF16Offset: range.location + range.length).line
                    }
                )
                platformTextView.highlightedLineNumbers = cursorLines
            } else {
                (textView as? CodeEditorPlatformTextView)?.highlightedLineNumber = cursorLocation.line
            }

            updateGutterState(for: textView)

            // 多光标时更新全选区快照
            let allRanges = textView.selectedRanges.map { $0.rangeValue }
            if allRanges.count > 1 {
                parent.document.markMultiSelection(allRanges)
            } else {
                parent.document.markSelection(selectedRange)
            }

            // 括号高亮（仅单光标时处理）
            if let platformTextView = textView as? CodeEditorPlatformTextView,
               !platformTextView.hasMarkedText(),
               platformTextView.selectedRanges.count <= 1 {
                let cursorOffset = textView.selectedRange().location
                let matchResult = CodeEditorBracketScanner.findMatch(
                    in: platformTextView.string,
                    cursorOffset: cursorOffset
                )
                platformTextView.applyBracketMatchHighlight(matchResult)
            } else if let platformTextView = textView as? CodeEditorPlatformTextView,
                      platformTextView.selectedRanges.count > 1 {
                // 多光标时清除括号高亮
                platformTextView.applyBracketMatchHighlight(nil)
            }
        }

        func publishVisibleLineRange(for textView: NSTextView) {
            guard let visibleLineRange = visibleLineRange(for: textView) else {
                return
            }

            guard visibleLineRange != lastPublishedVisibleLineRange else {
                return
            }

            lastPublishedVisibleLineRange = visibleLineRange
            parent.onVisibleLineRangeChange?(visibleLineRange)
            updateGutterState(for: textView)
        }

        func updateGutterState(for textView: NSTextView) {
            guard let textView = textView as? CodeEditorPlatformTextView,
                  let gutterView = gutterView(for: textView),
                  let scrollView = textView.enclosingScrollView else {
                return
            }

            let visibleRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            // Use document coordinates directly – the gutter's bounds.origin.y
            // is synced with the scroll view's content offset, so document-space
            // Y values produce correct visual alignment without conversion.
            let lineMetrics = textView.visibleLineMetrics(in: scrollView.contentView.bounds).map { metric in
                CodeEditorVisibleLineMetric(
                    line: metric.line,
                    rect: NSRect(x: 0, y: metric.rect.minY, width: gutterView.requiredWidth, height: metric.rect.height).integral,
                    baselineY: metric.baselineY
                )
            }
            let snapshot = CodeEditorGutterLineMetricsSnapshot(
                lineCount: textView.displayedLineCount,
                visibleLineRange: visibleRange,
                currentLine: textView.highlightedLineNumber,
                cursorLineNumbers: textView.highlightedLineNumbers,
                lineMetrics: lineMetrics,
                diagnosticsByLine: parent.diagnosticsByLine,
                gitDiffByLine: parent.gitDiffByLine,
                agentChangeDiffByLine: parent.agentChangeDiffByLine
            )
            gutterView.updateLayoutState(snapshot)
        }

        private func gutterView(for textView: CodeEditorPlatformTextView) -> CodeEditorGutterView? {
            var currentView = textView.enclosingScrollView?.superview
            while let view = currentView {
                if let containerView = view as? CodeEditorViewportContainerView {
                    return containerView.gutterView
                }
                currentView = view.superview
            }
            return nil
        }

        func applyFocus(to textView: NSTextView) {
            if let window = textView.window {
                window.makeFirstResponder(textView)
                return
            }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyFocus(to: textView)
            }
        }

        func applyRevealRequest(_ request: CodeEditorRevealRequest, to textView: CodeEditorPlatformTextView) {
            isApplyingProgrammaticUpdate = true
            textView.applyRevealRequest(request)
            isApplyingProgrammaticUpdate = false
            textView.updateHoverPresentation(nil)
            updateGutterState(for: textView)
        }

        func schedulePostUpdateRefresh(
            for textView: CodeEditorPlatformTextView,
            dirtyLineRange: ClosedRange<Int>?
        ) {
            let refreshID = UUID()
            pendingPostUpdateRefreshID = refreshID
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.pendingPostUpdateRefreshID == refreshID else { return }
                self.pendingPostUpdateRefreshID = nil
                self.publishSelection(for: textView)
                self.scheduleHighlight(for: textView, dirtyLineRange: dirtyLineRange)
            }
        }

        func scheduleHighlight(
            for textView: CodeEditorPlatformTextView,
            dirtyLineRange: ClosedRange<Int>?
        ) {
            if textView.hasMarkedText() {
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                cancelHighlight()
                return
            }

            let visibleLineRange = visibleLineRange(for: textView) ?? fullDocumentLineRange()
            publishVisibleLineRange(for: textView)
            let effectiveDirtyLineRange = dirtyLineRange ?? visibleLineRange
            let shouldSkipDuplicateSchedule =
                lastScheduledHighlightVersion == parent.document.version &&
                lastScheduledVisibleLineRange == visibleLineRange &&
                dirtyLineRange == nil

            guard !shouldSkipDuplicateSchedule else {
                return
            }

            lastScheduledHighlightVersion = parent.document.version
            lastScheduledVisibleLineRange = visibleLineRange

            let documentSnapshot = parent.document
            let request = highlightPipeline.makeViewportRequest(
                document: documentSnapshot,
                language: parent.language,
                visibleLineRange: visibleLineRange,
                dirtyLineRange: effectiveDirtyLineRange,
                appearance: currentAppearance(for: textView),
                fontSize: currentFontSize(for: textView)
            )
            guard !highlightPipeline.shouldSkipRealtimeHighlight(for: request, document: documentSnapshot) else {
                Task {
                    await highlightScheduler.cancel()
                }
                return
            }
            let debounceNanoseconds = parent.highlightDebounceNanoseconds
            let executionDelayNanoseconds = parent.highlightExecutionDelayNanoseconds
            let highlighter = parent.highlighter
            let pipeline = highlightPipeline

            Task {
                await highlightScheduler.schedule(
                    .init(request: request, textSnapshot: documentSnapshot.text),
                    debounceNanoseconds: debounceNanoseconds,
                    execute: { work in
                        if executionDelayNanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: executionDelayNanoseconds)
                        }
                        guard !Task.isCancelled else {
                            return nil
                        }
                        return pipeline.highlight(
                            request: work.request,
                            document: documentSnapshot,
                            highlighter: highlighter
                        )
                    },
                    onResult: { [weak self, weak textView] result in
                        guard let self, let textView else { return }
                        await MainActor.run {
                            self.applyHighlightResult(result, to: textView)
                        }
                    }
                )
            }

            // 高亮调度完成后同步触发 inlay hint 调度
            if parent.isInlayHintsEnabled {
                scheduleInlayHintRequest(for: textView)
            }
        }

        func fullDocumentLineRange() -> ClosedRange<Int> {
            1...max(parent.document.lineCount, 1)
        }

        private func cancelHighlight() {
            Task {
                await highlightScheduler.cancel()
            }
        }

        private func commitDisplayedText(
            from textView: CodeEditorPlatformTextView,
            preferPendingEdit: Bool
        ) {
            let currentText = textView.string
            let selectedRange = textView.selectedRange()

            // 多光标编辑：pendingEdit 无效，直接全文更新
            if isMultiCursorEdit {
                isMultiCursorEdit = false
                pendingEdit = nil
                let changeSet = parent.document.replaceAllForMultiCursorEdit(
                    text: currentText,
                    selectedRange: selectedRange
                )
                parent.text = currentText
                parent.onChangeSet?(changeSet)
                publishSelection(for: textView)
                publishVisibleLineRange(for: textView)
                updateGutterState(for: textView)
                scheduleHighlight(for: textView, dirtyLineRange: nil)
                return
            }

            let committedEdit = resolvedCommittedEdit(
                from: parent.document.text,
                to: currentText,
                preferredEdit: preferPendingEdit ? pendingEdit : nil
            )
            let change = parent.document.applyUserEdit(
                replacing: committedEdit.replacedRange,
                insertedText: committedEdit.insertedText,
                updatedText: currentText,
                selectedRange: selectedRange
            )
            pendingEdit = nil
            parent.text = currentText
            parent.onChangeSet?(change)
            publishSelection(for: textView)
            scheduleHighlight(for: textView, dirtyLineRange: dirtyLineRange(for: change))
        }

        private func resolvedCommittedEdit(
            from oldText: String,
            to newText: String,
            preferredEdit: PendingEdit?
        ) -> PendingEdit {
            if let preferredEdit,
               editMatchesTexts(preferredEdit, oldText: oldText, newText: newText) {
                return preferredEdit
            }

            return computeEditDelta(from: oldText, to: newText)
        }

        private func editMatchesTexts(_ edit: PendingEdit, oldText: String, newText: String) -> Bool {
            let oldNSString = oldText as NSString
            guard edit.replacedRange.location >= 0,
                  edit.replacedRange.upperBound <= oldNSString.length else {
                return false
            }

            let candidate = oldNSString.replacingCharacters(in: edit.replacedRange, with: edit.insertedText)
            return candidate == newText
        }

        private func computeEditDelta(from oldText: String, to newText: String) -> PendingEdit {
            let oldNSString = oldText as NSString
            let newNSString = newText as NSString
            let oldLength = oldNSString.length
            let newLength = newNSString.length

            var prefixLength = 0
            while prefixLength < oldLength,
                  prefixLength < newLength,
                  oldNSString.character(at: prefixLength) == newNSString.character(at: prefixLength) {
                prefixLength += 1
            }

            var oldSuffixLength = 0
            let maxSuffixLength = min(oldLength - prefixLength, newLength - prefixLength)
            while oldSuffixLength < maxSuffixLength,
                  oldNSString.character(at: oldLength - oldSuffixLength - 1) == newNSString.character(at: newLength - oldSuffixLength - 1) {
                oldSuffixLength += 1
            }

            let replacedRange = NSRange(
                location: prefixLength,
                length: oldLength - prefixLength - oldSuffixLength
            )
            let insertedText = newNSString.substring(with: NSRange(
                location: prefixLength,
                length: newLength - prefixLength - oldSuffixLength
            ))
            return PendingEdit(replacedRange: replacedRange, insertedText: insertedText)
        }

        private func applyHighlightResult(
            _ result: CodeEditorHighlightResult,
            to textView: CodeEditorPlatformTextView
        ) {
            guard result.version == parent.document.version, !textView.hasMarkedText() else {
                return
            }

            textView.latestHighlightResult = result
            _ = CodeEditorHighlightApplicator.apply(
                result,
                decorations: parent.decorations,
                to: textView,
                baseAttributes: baseAttributes(for: textView)
            )
            textView.latestAppliedHighlightVersion = result.version

            // Pair colorization（opt-in）
            if parent.isBracketPairColorizationEnabled,
               let storage = textView.textStorage {
                let visibleRange: NSRange
                if let visibleLineRange = visibleLineRange(for: textView) {
                    let startOffset = parent.document.utf16Offset(line: visibleLineRange.lowerBound, column: 1)
                    let endOffset = parent.document.utf16Offset(line: visibleLineRange.upperBound, column: 9999)
                    let clampedStart = max(0, startOffset)
                    let clampedEnd = min(endOffset, storage.length)
                    if clampedEnd > clampedStart {
                        visibleRange = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
                    } else {
                        visibleRange = NSRange(location: 0, length: storage.length)
                    }
                } else {
                    visibleRange = NSRange(location: 0, length: storage.length)
                }
                CodeEditorBracketPairColorizationService.colorize(
                    textView: textView,
                    visibleUTF16Range: visibleRange
                )
            }
        }

        func applyCachedHighlightPresentation(to textView: CodeEditorPlatformTextView) {
            guard !textView.hasMarkedText(),
                  let result = textView.latestHighlightResult,
                  result.version == parent.document.version else {
                return
            }

            _ = CodeEditorHighlightApplicator.apply(
                result,
                decorations: parent.decorations,
                to: textView,
                baseAttributes: baseAttributes(for: textView)
            )
            textView.latestAppliedHighlightVersion = result.version
        }

        private func baseAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            [
                .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: textView.textColor ?? NSColor.labelColor
            ]
        }

        private func currentAppearance(for textView: NSTextView) -> CodeHighlightAppearance {
            textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }

        private func currentFontSize(for textView: NSTextView) -> CGFloat {
            textView.font?.pointSize ?? NSFont.systemFontSize
        }

        private func visibleLineRange(for textView: NSTextView) -> ClosedRange<Int>? {
            guard
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return nil
            }

            layoutManager.ensureLayout(for: textContainer)
            let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let lineRange: FileLineRange
            if let textView = textView as? CodeEditorPlatformTextView {
                lineRange = textView.displayedLineRange(for: characterRange)
            } else {
                lineRange = parent.document.lineRange(for: characterRange)
            }
            return lineRange.startLine...max(lineRange.endLine, lineRange.startLine)
        }

        private func dirtyLineRange(for change: EditorChangeSet) -> ClosedRange<Int> {
            let insertedLength = (change.insertedText as NSString).length
            let dirtyRange = NSRange(
                location: change.replacedRange.location,
                length: max(change.replacedRange.length, insertedLength)
            )
            let fileLineRange = parent.document.lineRange(for: dirtyRange)
            return fileLineRange.startLine...max(fileLineRange.endLine, fileLineRange.startLine)
        }

        private func selectionSnapshot(for textView: NSTextView, text: String, range: NSRange) -> EditorSelectionSnapshot? {
            let source = text as NSString
            let safeLocation = max(0, min(range.location, source.length))
            let safeLength = max(0, min(range.length, source.length - safeLocation))
            let safeRange = NSRange(location: safeLocation, length: safeLength)
            guard safeRange.length > 0 else {
                return nil
            }

            let selectedText = source.substring(with: safeRange)
            let lineRange: FileLineRange
            if let displayedTextView = textView as? CodeEditorPlatformTextView {
                lineRange = displayedTextView.displayedLineRange(for: safeRange)
            } else {
                lineRange = parent.document.lineRange(for: safeRange)
            }
            return EditorSelectionSnapshot(
                text: selectedText,
                lineRange: lineRange
            )
        }
    }
}

@MainActor
enum CodeEditorHighlightApplicator {
    static func apply(
        _ result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        to textView: NSTextView,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> Set<Int> {
        guard let storage = textView.textStorage else { return [] }
        let fragmentsByLine = Dictionary(uniqueKeysWithValues: result.lineFragments.map { ($0.line, $0) })
        let changedLines = changedLineSet(
            result: result,
            decorations: decorations,
            textView: textView
        )

        guard changedLines.isEmpty == false else {
            if let textView = textView as? CodeEditorPlatformTextView {
                updateFingerprints(result: result, decorations: decorations, textView: textView)
                textView.lastReappliedLines = []
            }
            return []
        }

        let selectedRange = textView.selectedRange()
        let typingAttributes = textView.typingAttributes

        storage.beginEditing()

        for line in changedLines.sorted() {
            guard let fragment = fragmentsByLine[line], fragment.utf16Range.upperBound <= storage.length else {
                continue
            }

            storage.setAttributes(baseAttributes, range: fragment.utf16Range)
            fragment.attributedString.enumerateAttributes(
                in: NSRange(location: 0, length: fragment.attributedString.length),
                options: []
            ) { attributes, range, _ in
                let targetRange = NSRange(
                    location: fragment.utf16Range.location + range.location,
                    length: range.length
                )
                storage.addAttributes(attributes, range: targetRange)
            }

            for span in decorations.spansByLine[line] ?? [] {
                let safeRange = clampedDecorationRange(span.utf16Range, storageLength: storage.length)
                guard safeRange.length > 0 else {
                    continue
                }
                storage.addAttributes(decorationAttributes(for: span.kind), range: safeRange)
            }
        }

        storage.endEditing()

        textView.setSelectedRange(selectedRange)
        textView.typingAttributes = typingAttributes

        if let textView = textView as? CodeEditorPlatformTextView {
            updateFingerprints(result: result, decorations: decorations, textView: textView)
            textView.lastReappliedLines = changedLines.sorted()
        }

        return changedLines
    }

    private static func changedLineSet(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: NSTextView
    ) -> Set<Int> {
        let newFingerprints = combinedFingerprints(result: result, decorations: decorations)
        guard let textView = textView as? CodeEditorPlatformTextView else {
            return Set(newFingerprints.keys)
        }

        return Set(newFingerprints.compactMap { line, fingerprint in
            textView.appliedLinePresentationFingerprints[line] == fingerprint ? nil : line
        })
    }

    private static func updateFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot,
        textView: CodeEditorPlatformTextView
    ) {
        for (line, fingerprint) in combinedFingerprints(result: result, decorations: decorations) {
            textView.appliedLinePresentationFingerprints[line] = fingerprint
        }
    }

    private static func combinedFingerprints(
        result: CodeEditorHighlightResult,
        decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        let decorationFingerprints = decorationFingerprints(for: decorations)
        return Dictionary(uniqueKeysWithValues: result.lineFragments.map { fragment in
            let combined = fragment.fingerprint ^ (decorationFingerprints[fragment.line] ?? 0)
            return (fragment.line, combined)
        })
    }

    private static func decorationFingerprints(
        for decorations: CodeEditorDecorationSnapshot
    ) -> [Int: Int] {
        decorations.spansByLine.mapValues { spans in
            var hasher = Hasher()
            for span in spans.sorted(by: { lhs, rhs in
                if lhs.utf16Range.location == rhs.utf16Range.location {
                    return lhs.utf16Range.length < rhs.utf16Range.length
                }
                return lhs.utf16Range.location < rhs.utf16Range.location
            }) {
                hasher.combine(span.utf16Range.location)
                hasher.combine(span.utf16Range.length)
                hasher.combine(String(describing: span.kind))
            }
            return hasher.finalize()
        }
    }

    private static func clampedDecorationRange(_ range: NSRange, storageLength: Int) -> NSRange {
        let location = max(0, min(range.location, storageLength))
        let length = max(0, min(range.length, storageLength - location))
        return NSRange(location: location, length: length)
    }

    private static func decorationAttributes(
        for kind: CodeEditorDecorationKind
    ) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .findMatch:
            return [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.28)]
        case .activeFindMatch:
            return [.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.35)]
        case .selectionMatch:
            return [.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18)]
        case let .diagnosticUnderline(severity):
            return [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: underlineColor(for: severity)
            ]
        }
    }

    private static func underlineColor(for severity: LSPDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error:
            return .systemRed
        case .warning:
            return .systemOrange
        case .information:
            return .systemBlue
        case .hint:
            return .systemGray
        }
    }
}

// MARK: - Completion Key Delegate

/// 补全面板键盘操作协议，由 Coordinator 实现，从 keyDown 桥接调用。
@MainActor
protocol CompletionKeyDelegate: AnyObject {
    var isCompletionPanelVisible: Bool { get }
    func acceptCompletion()
    func dismissCompletion()
    func selectNextCompletion()
    func selectPrevCompletion()
}

/// 签名帮助键盘操作协议，由 Coordinator 实现，从 keyDown 桥接调用。
@MainActor
protocol SignatureHelpKeyDelegate: AnyObject {
    var isSignatureHelpPanelVisible: Bool { get }
    var isSignatureHelpActive: Bool { get }
    func cancelSignatureHelp()
    func nextSignatureOverload()
    func previousSignatureOverload()
    func invokeSignatureHelp(at offset: Int)
}

extension CodeEditorTextView.Coordinator: CompletionKeyDelegate {
    var isCompletionPanelVisible: Bool {
        completionPanel?.panel.isVisible ?? false
    }

    func acceptCompletion() {
        guard let panel = completionPanel,
              let item = panel.acceptSelectedItem() else { return }
        // 找到关联的 textView: 通过 panel.onAccept 负责回调，这里直接触发
        panel.onAccept?(item)
    }

    func dismissCompletion() {
        completionTrigger.dismiss()
    }

    func selectNextCompletion() {
        completionPanel?.selectNext()
    }

    func selectPrevCompletion() {
        completionPanel?.selectPrevious()
    }
}

extension CodeEditorTextView.Coordinator: SignatureHelpKeyDelegate {
    var isSignatureHelpPanelVisible: Bool {
        signatureHelpPanel?.isVisible ?? false
    }

    var isSignatureHelpActive: Bool {
        signatureHelpTrigger.isActive
    }

    func cancelSignatureHelp() {
        signatureHelpTrigger.cancel()
    }

    func nextSignatureOverload() {
        signatureHelpTrigger.next()
    }

    func previousSignatureOverload() {
        signatureHelpTrigger.previous()
    }

    func invokeSignatureHelp(at offset: Int) {
        signatureHelpTrigger.invoke(cursorOffset: offset)
    }
}

// MARK: - Indent Guide Config

/// 缩进参考线所需配置，从 CodeEditorIndentationStatus 派生。
struct CodeEditorIndentGuideConfig: Equatable, Sendable {
    let indentWidth: Int   // 每级缩进的字符数，<=0 时禁用
    let useTabs: Bool

    static let disabled = CodeEditorIndentGuideConfig(indentWidth: 0, useTabs: false)

    init(indentWidth: Int, useTabs: Bool) {
        self.indentWidth = indentWidth
        self.useTabs = useTabs
    }

    init(from status: CodeEditorIndentationStatus) {
        switch status.kind {
        case .spaces:
            self.init(indentWidth: max(1, status.width), useTabs: false)
        case .tabs:
            self.init(indentWidth: max(1, status.width), useTabs: true)
        case .unknown:
            self.init(indentWidth: 4, useTabs: false) // 默认 4 spaces
        }
    }
}

final class CodeEditorPlatformTextView: NSTextView {
    var latestAppliedHighlightVersion: Int?
    var latestHighlightResult: CodeEditorHighlightResult?

    // MARK: - Indent Guides

    /// 缩进参考线配置，由 Coordinator 在 updateNSView 时写入。
    /// indentWidth <= 0 时不绘制参考线。
    var indentGuideConfig: CodeEditorIndentGuideConfig = .disabled {
        didSet {
            guard indentGuideConfig != oldValue else { return }
            setNeedsDisplay(visibleRect)
        }
    }

    // MARK: - Bracket Match Highlight
    /// 当前已应用的括号高亮范围（用于后续清除）
    private var appliedBracketMatchRanges: (open: NSRange, close: NSRange)?

    /// 括号高亮背景色
    static let bracketMatchBackgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.22)
    var latestDecorationSnapshot: CodeEditorDecorationSnapshot = .empty(version: 0, lineRange: 1...1)
    var currentDocumentVersion: Int = 0
    var compositionStateChangeHandler: ((CodeEditorPlatformTextView) -> Void)?
    var semanticIntentHandler: ((CodeEditorSemanticIntent) -> Void)?
    var findIntentHandler: ((CodeEditorFindIntent) -> Void)?

    // MARK: - Completion
    /// 键盘操作代理（Coordinator 实现），当面板可见时拦截 Tab/Enter/Esc/↑↓ 键。
    weak var completionDelegate: (any CompletionKeyDelegate)?

    // MARK: - Signature Help
    /// 签名帮助键盘代理（Coordinator 实现）
    weak var signatureHelpDelegate: (any SignatureHelpKeyDelegate)?

    // MARK: - Agent Change Diff（F24 Inline Background）

    /// Agent 修改的行级 diff，由 Coordinator 更新，drawBackground 消费。
    var agentChangeDiffByLine: [Int: CodeEditorGitDiffKind] = [:] {
        didSet {
            guard agentChangeDiffByLine != oldValue else { return }
            needsDisplay = true
        }
    }

    // MARK: - Inlay Hints

    /// 当前 viewport 的 inlay hints 快照。
    /// 由 Coordinator 在主线程写入，drawBackground 消费。
    var currentInlayHintSnapshot: CodeEditorInlayHintSnapshot = .empty {
        didSet {
            guard currentInlayHintSnapshot.documentVersion != oldValue.documentVersion
                || currentInlayHintSnapshot.hintsByLine != oldValue.hintsByLine
            else { return }
            setNeedsDisplay(visibleRect)
        }
    }

    // MARK: - Ghost Text

    /// 当前 AI ghost text 建议快照（nil = 无建议）。
    /// 由 Coordinator 在主线程写入，drawBackground 消费（不修改 NSTextStorage）。
    var currentGhostText: CodeEditorGhostTextSnapshot? {
        didSet {
            guard currentGhostText?.generation != oldValue?.generation
                || currentGhostText?.text != oldValue?.text
            else { return }
            needsDisplay = true
        }
    }

    /// accept 操作进行中时设为 true，防止 setSelectedRanges 重写误清除 ghost text。
    private var isAcceptingGhostText = false

    /// 光标偏离失效（对齐 Zed update_visible_edit_prediction invalidation_range）。
    /// 若光标移动到不同于 insertionOffset 的位置，自动清除 ghost text。
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        guard !isAcceptingGhostText else { return }
        if let snap = currentGhostText {
            let cursor = selectedRange().location
            if cursor != snap.insertionOffset {
                currentGhostText = nil
            }
        }
    }

    func clearGhostText() {
        currentGhostText = nil
    }

    /// 提取 ghost text 请求所需的前缀/后缀上下文（各最多 200/20 行）
    func extractGhostTextContext(language: String? = nil) -> (prefix: String, suffix: String, language: String)? {
        guard let storage = textStorage else { return nil }
        let fullText = storage.string
        let cursorPos = selectedRange().location
        guard cursorPos <= fullText.utf16.count else { return nil }

        let utf16 = fullText.utf16
        guard cursorPos <= utf16.count else { return nil }
        let prefixEndIdx = utf16.index(utf16.startIndex, offsetBy: cursorPos)

        let prefixUTF16 = String(utf16[utf16.startIndex..<prefixEndIdx]) ?? ""
        let suffixUTF16 = String(utf16[prefixEndIdx...]) ?? ""

        let prefixLines = prefixUTF16.components(separatedBy: "\n")
        let suffixLines = suffixUTF16.components(separatedBy: "\n")

        let prefix = prefixLines.suffix(200).joined(separator: "\n")
        let suffix = suffixLines.prefix(20).joined(separator: "\n")

        return (prefix: prefix, suffix: suffix, language: language ?? "swift")
    }

    var appliedLinePresentationFingerprints: [Int: Int] = [:]
    var lastReappliedLines: [Int] = []
    var highlightedLineNumbers: Set<Int> = [] {
        didSet {
            guard highlightedLineNumbers != oldValue else { return }
            for line in oldValue { invalidateLine(line) }
            for line in highlightedLineNumbers { invalidateLine(line) }
        }
    }

    /// 向后兼容：单光标读写单个行
    var highlightedLineNumber: Int? {
        get { highlightedLineNumbers.first }
        set {
            if let n = newValue {
                highlightedLineNumbers = [n]
            } else {
                highlightedLineNumbers = []
            }
        }
    }
    private var displayedLineIndex = CodeEditorLineIndex(text: "")
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverPopover = NSPopover()
    private var currentHoverPresentation: CodeEditorHoverPresentation?

    var displayedLineCount: Int {
        displayedLineIndex.lineCount
    }

    var currentHoverMarkdown: String? {
        currentHoverPresentation?.markdown
    }

    var isHoverPopoverShown: Bool {
        hoverPopover.isShown
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        hoverPopover.behavior = .semitransient
        hoverPopover.animates = false
    }

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

    private func drawAgentDiffBackground(in rect: NSRect) {
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

    private func drawInlayHints(in rect: NSRect) {
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

    private func drawSingleInlayHint(
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

    private func drawGhostText(_ snapshot: CodeEditorGhostTextSnapshot, in rect: NSRect) {
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

    // MARK: - Ghost Text Acceptance

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
            var updated = Array(current.dropLast()) + [expandedRange]
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

    func refreshDisplayedTextState() {
        displayedLineIndex.replaceAll(with: string)
    }

    func displayedLocation(ofUTF16Offset offset: Int) -> CodeEditorTextLocation {
        displayedLineIndex.location(ofUTF16Offset: offset)
    }

    func displayedLineRange(for characterRange: NSRange) -> FileLineRange {
        displayedLineIndex.lineRange(forUTF16Range: characterRange)
    }

    func visibleLineMetrics(in visibleRect: NSRect) -> [CodeEditorVisibleLineMetric] {
        guard let layoutManager,
              let textContainer,
              let visibleLineRange = displayedVisibleLineRange(in: visibleRect, layoutManager: layoutManager, textContainer: textContainer) else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let baselineOffset = font?.ascender ?? 0

        return visibleLineRange.compactMap { line in
            guard let rect = displayedLineRect(for: line, layoutManager: layoutManager, textContainer: textContainer) else {
                return nil
            }

            return CodeEditorVisibleLineMetric(
                line: line,
                rect: rect,
                baselineY: rect.minY + baselineOffset
            )
        }
    }

    func backgroundRect(forLine line: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        return displayedLineRect(for: line, layoutManager: layoutManager, textContainer: textContainer)
    }

    func emitSemanticIntent(_ intent: CodeEditorSemanticIntent) {
        guard !hasMarkedText() else {
            return
        }

        semanticIntentHandler?(intent)
    }

    func semanticPosition(line: Int, column: Int) -> CodeEditorSemanticPosition {
        let utf16Offset = displayedLineIndex.utf16Offset(line: line, column: column)
        let location = displayedLineIndex.location(ofUTF16Offset: utf16Offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: utf16Offset,
            version: currentDocumentVersion
        )
    }

    func codePosition(for utf16Offset: Int) -> (line: Int, character: Int) {
        let location = displayedLineIndex.location(ofUTF16Offset: utf16Offset)
        return (
            line: max(0, location.line - 1),
            character: max(0, location.column - 1)
        )
    }

    func applyRevealRequest(_ request: CodeEditorRevealRequest) {
        let offset = displayedLineIndex.utf16Offset(line: request.line, column: request.column)
        let selectedRange = NSRange(location: offset, length: 0)
        setSelectedRange(selectedRange)
        scrollRangeToVisible(selectedRange)
    }

    func updateHoverPresentation(_ presentation: CodeEditorHoverPresentation?) {
        currentHoverPresentation = presentation

        guard let presentation else {
            if hoverPopover.isShown {
                hoverPopover.performClose(nil)
            }
            return
        }

        guard let anchorRect = hoverAnchorRect(forUTF16Offset: presentation.position.utf16Offset) else {
            return
        }

        let content = Text(presentation.markdown)
            .font(.system(size: 12))
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(maxWidth: 320, alignment: .leading)
        hoverPopover.contentViewController = NSHostingController(rootView: content)

        if hoverPopover.isShown {
            hoverPopover.performClose(nil)
        }

        hoverPopover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
    }

    private func displayedUTF16LineRange(forLine line: Int) -> NSRange {
        let safeLine = max(1, min(line, displayedLineIndex.lineCount))
        let startOffset = displayedLineIndex.lineStartOffset(forLine: safeLine)
        let endOffset = safeLine < displayedLineIndex.lineCount
            ? displayedLineIndex.lineStartOffset(forLine: safeLine + 1)
            : (string as NSString).length

        return NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }

    private func displayedVisibleLineRange(
        in visibleRect: NSRect,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> ClosedRange<Int>? {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lineRange = displayedLineRange(for: characterRange)
        return lineRange.startLine...max(lineRange.endLine, lineRange.startLine)
    }

    private func displayedLineRect(
        for line: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        if layoutManager.numberOfGlyphs == 0 {
            let origin = textContainerOrigin
            let height = layoutManager.defaultLineHeight(for: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            return NSRect(x: 0, y: origin.y, width: bounds.width, height: height).integral
        }

        let characterRange = displayedUTF16LineRange(forLine: line)
        let safeLength: Int
        let safeLocation: Int
        if characterRange.length == 0 {
            safeLocation = max(0, min(characterRange.location, (string as NSString).length))
            safeLength = 0
        } else {
            safeLocation = characterRange.location
            safeLength = characterRange.length
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeLocation, length: safeLength),
            actualCharacterRange: nil
        )

        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.isEmpty {
            let fallbackLocation = max(0, min(safeLocation, (string as NSString).length))
            let fallbackGlyphIndex = layoutManager.glyphIndexForCharacter(at: fallbackLocation)
            rect = layoutManager.lineFragmentRect(forGlyphAt: fallbackGlyphIndex, effectiveRange: nil)
        }

        guard !rect.isEmpty else {
            return nil
        }

        let origin = textContainerOrigin
        rect.origin.x = 0
        rect.origin.y += origin.y
        rect.size.width = bounds.width
        return rect.integral
    }

    private func invalidateLine(_ line: Int?) {
        guard let line,
              let rect = backgroundRect(forLine: line) else {
            return
        }

        setNeedsDisplay(rect)
    }

    private func semanticPosition(at point: NSPoint) -> CodeEditorSemanticPosition? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let safeOffset = max(0, min(characterIndex, (string as NSString).length))
        let location = displayedLineIndex.location(ofUTF16Offset: safeOffset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: safeOffset,
            version: currentDocumentVersion
        )
    }

    private func semanticPositionForSelection() -> CodeEditorSemanticPosition? {
        let offset = max(0, min(selectedRange().location, (string as NSString).length))
        let location = displayedLineIndex.location(ofUTF16Offset: offset)
        return CodeEditorSemanticPosition(
            line: location.line,
            column: location.column,
            utf16Offset: offset,
            version: currentDocumentVersion
        )
    }

    private func hoverAnchorRect(forUTF16Offset offset: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer else {
            return nil
        }

        let safeOffset = max(0, min(offset, (string as NSString).length))
        let glyphIndex = min(
            layoutManager.glyphIndexForCharacter(at: safeOffset),
            max(layoutManager.numberOfGlyphs - 1, 0)
        )
        let lineFragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        guard !lineFragRect.isEmpty else { return nil }

        let origin = textContainerOrigin
        return NSRect(
            x: origin.x + glyphLocation.x,
            y: origin.y + lineFragRect.minY,
            width: max(1, font?.maximumAdvancement.width ?? NSFont.systemFontSize * 0.6),
            height: lineFragRect.height
        ).integral
    }

    // MARK: - Bracket Match Highlight

    /// 应用括号高亮（清除旧的后应用新的）。
    /// 若 result 为 nil 则只清除旧高亮。
    func applyBracketMatchHighlight(_ result: CodeEditorBracketMatchResult?) {
        guard let layoutManager else { return }
        // 清除旧的高亮
        if let old = appliedBracketMatchRanges {
            let fullLength = (string as NSString).length
            let safeOpen = clampRange(old.open, max: fullLength)
            let safeClose = clampRange(old.close, max: fullLength)
            if safeOpen.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeOpen)
            }
            if safeClose.length > 0 {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: safeClose)
            }
        }
        appliedBracketMatchRanges = nil

        guard let result else { return }
        let fullLength = (string as NSString).length
        let safeOpen = clampRange(result.openRange, max: fullLength)
        let safeClose = clampRange(result.closeRange, max: fullLength)
        guard safeOpen.length > 0, safeClose.length > 0 else { return }

        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Self.bracketMatchBackgroundColor,
            forCharacterRange: safeOpen
        )
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: Self.bracketMatchBackgroundColor,
            forCharacterRange: safeClose
        )
        appliedBracketMatchRanges = (safeOpen, safeClose)
    }

    private func clampRange(_ range: NSRange, max length: Int) -> NSRange {
        let location = Swift.max(0, Swift.min(range.location, length))
        let safeLength = Swift.max(0, Swift.min(range.length, length - location))
        return NSRange(location: location, length: safeLength)
    }

    // MARK: - Indent Guide Drawing

    private static let indentGuideInactiveColor = NSColor.separatorColor.withAlphaComponent(0.35)
    private static let indentGuideActiveColor   = NSColor.separatorColor.withAlphaComponent(0.70)

    private func drawIndentGuides(in rect: NSRect) {
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
    private func measureCharWidth(font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (" " as NSString).size(withAttributes: attrs)
        return size.width
    }

    private struct IndentGuideActiveRange {
        let lineRange: ClosedRange<Int>  // 1-indexed 逻辑行
        let depth: Int                    // 0-indexed depth（对应 indentLevel - 1）
    }

    private func computeActiveIndentGuideRange(
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

private struct PendingEdit {
    let replacedRange: NSRange
    let insertedText: String
}

// MARK: - Completion Helpers

extension CodeEditorPlatformTextView {
    /// 光标前的当前词（word boundary: alphanumeric + underscore + non-ASCII）。
    func prefixWordBeforeCursor(maxLength: Int = 200) -> String {
        let offset = selectedRange().location
        let utf16 = string.utf16
        guard offset > 0, offset <= utf16.count else { return "" }
        var start = offset
        while start > 0 {
            let idx = utf16.index(utf16.startIndex, offsetBy: start - 1)
            let char = utf16[idx]
            // word character: alphanumeric, _, or non-ASCII
            let isWord = char == UInt16(0x5F) /* _ */
                || (char >= 0x30 && char <= 0x39)   // 0-9
                || (char >= 0x41 && char <= 0x5A)   // A-Z
                || (char >= 0x61 && char <= 0x7A)   // a-z
                || char > 0x7F                       // non-ASCII (Unicode identifiers)
            guard isWord else { break }
            start -= 1
            if offset - start > maxLength { break }
        }
        let startIdx = utf16.index(utf16.startIndex, offsetBy: start)
        let endIdx = utf16.index(utf16.startIndex, offsetBy: offset)
        return String(utf16[startIdx..<endIdx]) ?? ""
    }

    /// 光标左侧的上一个字符（用于 trigger character 检测）。
    var lastTypedCharacter: String? {
        let offset = selectedRange().location
        guard offset > 0 else { return nil }
        let utf16 = string.utf16
        guard offset <= utf16.count else { return nil }
        let idx = utf16.index(utf16.startIndex, offsetBy: offset - 1)
        return String(utf16[idx])
    }

    /// 当前光标在本视图坐标系的矩形（用于补全面板定位）。
    var cursorRect: NSRect {
        let offset = selectedRange().location
        guard let manager = layoutManager,
              let container = textContainer else { return .zero }
        let glyphIndex = min(manager.glyphIndexForCharacter(at: offset),
                             max(manager.numberOfGlyphs - 1, 0))
        let lineFragRect = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = manager.location(forGlyphAt: glyphIndex)
        return NSRect(
            x: textContainerOrigin.x + glyphLocation.x,
            y: textContainerOrigin.y + lineFragRect.minY,
            width: 2,
            height: lineFragRect.height
        )
    }
}