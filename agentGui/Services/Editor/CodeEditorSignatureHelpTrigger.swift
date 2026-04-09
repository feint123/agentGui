// agentGui/Services/Editor/CodeEditorSignatureHelpTrigger.swift

import Foundation

// MARK: - State

private enum SignatureHelpState {
    case `default`
    case pending(generation: Int, previousHelp: LSPSignatureHelp?)
    case active(help: LSPSignatureHelp)

    var isTriggered: Bool {
        switch self {
        case .default: return false
        case .pending, .active: return true
        }
    }

    var activeHelp: LSPSignatureHelp? {
        if case .active(let h) = self { return h }
        if case .pending(_, let prev) = self { return prev }
        return nil
    }
}

// MARK: - CodeEditorSignatureHelpTrigger

/// 签名帮助触发状态机（对标 VSCode ParameterHintsModel）
/// - 仅 trigger char 时发新请求
/// - retrigger char / ContentChange 仅在 active/pending 时发 retrigger
/// - cancel 后转回 .default 并通知 onSessionChange(nil)
@MainActor
final class CodeEditorSignatureHelpTrigger {

    // MARK: - Callbacks (injected by CodeEditorTextView.Coordinator)

    /// 派发 LSP 请求，回调在 @MainActor 执行
    var requestSignatureHelp: ((SignatureHelpTriggerContext, @MainActor @escaping (LSPSignatureHelp?) -> Void) -> Void)?

    /// 状态更新时回调（nil = 隐藏浮层）
    var onSessionChange: ((LSPSignatureHelp?) -> Void)?

    // MARK: - Private state

    private var state: SignatureHelpState = .default
    private var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    // MARK: - Computed state

    var isActive: Bool {
        if case .default = state { return false }
        return true
    }

    // MARK: - Trigger / Retrigger

    /// 用户键入字符后调用
    func handleTyping(
        char: String,
        cursorOffset: Int,
        triggerCharacters: [String],
        retriggerCharacters: [String]
    ) {
        let isTrigger = triggerCharacters.contains(char)
        let isRetrigger = state.isTriggered && retriggerCharacters.contains(char)

        if isTrigger {
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char,
                    isRetrigger: state.isTriggered,
                    activeSignatureHelp: state.activeHelp
                )
            )
        } else if isRetrigger {
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char,
                    isRetrigger: true,
                    activeSignatureHelp: state.activeHelp
                )
            )
        } else if state.isTriggered {
            // 普通字符 + active → contentChange retrigger
            scheduleTrigger(
                context: SignatureHelpTriggerContext(
                    triggerKind: .contentChange,
                    triggerCharacter: nil,
                    isRetrigger: true,
                    activeSignatureHelp: state.activeHelp
                )
            )
        }
    }

    /// 手动触发（Ctrl+Cmd+Space 快捷键）
    func invoke(cursorOffset: Int) {
        scheduleTrigger(
            context: SignatureHelpTriggerContext(
                triggerKind: .invoked,
                triggerCharacter: nil,
                isRetrigger: state.isTriggered,
                activeSignatureHelp: state.activeHelp
            ),
            delay: 0
        )
    }

    // MARK: - Cancel

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        if case .default = state { return }
        state = .default
        onSessionChange?(nil)
    }

    // MARK: - Overload Navigation

    func next() {
        guard case .active(let help) = state, help.signatures.count > 1 else { return }
        let nextIdx = (help.activeSignature + 1) % help.signatures.count
        let updated = LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: nextIdx,
            activeParameter: help.activeParameter
        )
        state = .active(help: updated)
        onSessionChange?(updated)
    }

    func previous() {
        guard case .active(let help) = state, help.signatures.count > 1 else { return }
        let count = help.signatures.count
        let prevIdx = (help.activeSignature + count - 1) % count
        let updated = LSPSignatureHelp(
            signatures: help.signatures,
            activeSignature: prevIdx,
            activeParameter: help.activeParameter
        )
        state = .active(help: updated)
        onSessionChange?(updated)
    }

    // MARK: - Private

    private func scheduleTrigger(
        context: SignatureHelpTriggerContext,
        delay: UInt64 = 120_000_000   // 120ms，对标 VSCode DEFAULT_DELAY
    ) {
        debounceTask?.cancel()
        generation &+= 1
        let currentGeneration = generation

        if delay == 0 {
            doTrigger(context: context, generation: currentGeneration)
            return
        }

        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self.doTrigger(context: context, generation: currentGeneration)
        }
    }

    private func doTrigger(context: SignatureHelpTriggerContext, generation: Int) {
        let previousHelp = state.activeHelp
        state = .pending(generation: generation, previousHelp: previousHelp)

        requestSignatureHelp?(context) { [weak self] result in
            guard let self else { return }
            // 代际仲裁：仅当响应与当前 pending generation 匹配时才更新
            guard case .pending(let pendingGen, _) = self.state,
                  pendingGen == generation else { return }

            if let help = result, help.isValid {
                self.state = .active(help: help)
                self.onSessionChange?(help)
            } else {
                self.cancel()
            }
        }
    }
}
