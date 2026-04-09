import AppKit

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
