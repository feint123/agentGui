// agentGui/Services/Editor/CodeEditorCompletionTrigger.swift
import Foundation
import AppKit

/// 管理代码补全触发状态机。
/// 对应 VSCode SuggestModel 的职责：
///   - 去抖（150ms），防止快速输入时频繁发起 LSP 请求
///   - trigger character 立即触发（不去抖）
///   - 代际取消：新触发到来时取消旧请求
///   - 客户端前缀重过滤：补全会话打开时追加输入只需本地过滤
@MainActor
final class CodeEditorCompletionTrigger {
    // MARK: - Configuration
    static let debounceNanoseconds: UInt64 = 150_000_000 // 150ms
    static let maxItems = 100 // 列表最多展示条数

    // MARK: - State
    private var debounceTask: Task<Void, Never>?
    private var cachedAllItems: [CodeEditorCompletionItem] = []  // 最近一次 LSP 结果全集
    private var lastFetchPrefixWord = ""                          // 发起请求时的前缀
    private(set) var currentSession: CodeEditorCompletionSession? // nil = 面板关闭

    // MARK: - Callbacks
    var onSessionChange: ((CodeEditorCompletionSession?) -> Void)?

    // MARK: - Dependencies (injected)
    var requestCompletion: ((CompletionTriggerContext, @escaping ([CodeEditorCompletionItem]?) -> Void) -> Void)?
    var cancelRequest: (() -> Void)?

    // MARK: - Public API

    /// 用户键入字符后调用。
    /// - Parameters:
    ///   - char: 刚输入的字符（单个 Unicode Scalar string）
    ///   - cursorOffset: 当前光标 utf16 偏移
    ///   - prefixWord: 光标前的当前词（如 "myFu"）
    ///   - triggerCharacters: 来自 server capabilities 的 trigger characters
    func handleTyping(
        char: String,
        cursorOffset: Int,
        prefixWord: String,
        triggerCharacters: [String]
    ) {
        // IME 组合输入期间不触发（调用方负责在 hasMarkedText 时不调用此方法）
        // Trigger character: 立即触发，不去抖
        if triggerCharacters.contains(char) {
            debounceTask?.cancel()
            debounceTask = nil
            scheduleFetch(
                context: CompletionTriggerContext(
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    triggerKind: .triggerCharacter,
                    triggerCharacter: char
                )
            )
            return
        }

        // 若已有会话打开，尝试客户端重过滤（对应 VSCode _onNewContext refilter）
        if currentSession != nil, !cachedAllItems.isEmpty {
            let filtered = Self.clientFilter(items: cachedAllItems, prefix: prefixWord)
            if filtered.isEmpty {
                // 过滤后为空：关闭面板
                dismiss()
            } else {
                // 有结果：直接更新会话，不重发 LSP 请求
                let updated = CodeEditorCompletionSession(
                    cursorOffset: cursorOffset,
                    prefixWord: prefixWord,
                    items: Array(filtered.prefix(Self.maxItems)),
                    selectedIndex: 0,
                    isLoading: false
                )
                publishSession(updated)
            }
            // 但仍去抖发起新请求，以刷新完整候选列表（服务端可能有更多）
        }

        // Auto-trigger 去抖
        guard CompletionTriggerContext.shouldAutoTrigger(prefixWord: prefixWord) else {
            if currentSession != nil { dismiss() }
            return
        }
        debounceTask?.cancel()
        let ctx = CompletionTriggerContext(
            cursorOffset: cursorOffset,
            prefixWord: prefixWord,
            triggerKind: .invoked,
            triggerCharacter: nil
        )
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.scheduleFetch(context: ctx)
        }
    }

    /// 用户移动光标（非输入）时调用。
    /// - 若光标离开当前词范围，关闭面板。
    func handleCursorMove(prefixWord: String) {
        guard currentSession != nil else { return }
        if prefixWord.isEmpty {
            dismiss()
        }
    }

    /// Tab / Enter 选中项插入后调用：重置所有状态。
    func confirmed() {
        debounceTask?.cancel()
        debounceTask = nil
        cachedAllItems = []
        lastFetchPrefixWord = ""
        publishSession(nil)
    }

    /// Esc 或失焦时调用。
    func dismiss() {
        debounceTask?.cancel()
        debounceTask = nil
        cancelRequest?()
        cachedAllItems = []
        lastFetchPrefixWord = ""
        publishSession(nil)
    }

    // MARK: - Client-side filter (static, testable)

    /// 客户端前缀过滤（case-insensitive hasPrefix 匹配 filterText）。
    /// 对应 VSCode CompletionModel 的轻量前缀过滤。
    static func clientFilter(
        items: [CodeEditorCompletionItem],
        prefix: String
    ) -> [CodeEditorCompletionItem] {
        guard !prefix.isEmpty else { return items }
        let lower = prefix.lowercased()
        return items.filter { $0.filterText.lowercased().hasPrefix(lower) }
    }

    // MARK: - Private

    private func scheduleFetch(context: CompletionTriggerContext) {
        // 显示 loading 状态（如面板已打开则不新建 loading 会话，避免闪烁）
        if currentSession == nil {
            publishSession(.loading)
        }
        lastFetchPrefixWord = context.prefixWord
        requestCompletion?(context) { [weak self] items in
            guard let self else { return }
            guard let items else {
                // nil = 被代际取消，不更新 UI
                return
            }
            self.cachedAllItems = items
            let filtered = Self.clientFilter(items: items, prefix: context.prefixWord)
            if filtered.isEmpty {
                self.dismiss()
                return
            }
            let session = CodeEditorCompletionSession(
                cursorOffset: context.cursorOffset,
                prefixWord: context.prefixWord,
                items: Array(filtered.prefix(Self.maxItems)),
                selectedIndex: 0,
                isLoading: false
            )
            self.publishSession(session)
        }
    }

    private func publishSession(_ session: CodeEditorCompletionSession?) {
        currentSession = session
        onSessionChange?(session)
    }
}
