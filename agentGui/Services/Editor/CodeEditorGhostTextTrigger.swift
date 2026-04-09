// agentGui/Services/Editor/CodeEditorGhostTextTrigger.swift
import Foundation

/// Ghost text 触发器：防抖 + IME 安全 + 代际递增
/// 参照 CodeEditorCompletionTrigger 和 Zed refresh_edit_prediction 设计
@MainActor
final class CodeEditorGhostTextTrigger {

    typealias ContextProvider = () -> (prefix: String, suffix: String, language: String)?

    /// 触发后回调：(generation: Int, contextProvider: ContextProvider)
    var onRequestGhostText: ((Int, ContextProvider) -> Void)?

    private let debounceMs: Int
    private(set) var generation: Int = 0
    private var debounceTask: Task<Void, Never>?

    init(debounceMs: Int = 500) {
        self.debounceMs = debounceMs
    }

    /// 每次文本变化时调用
    func handleChange(
        isIMEActive: Bool,
        isGhostTextEnabled: Bool,
        contextProvider: @escaping ContextProvider = { nil }
    ) {
        // IME 输入中或功能关闭 → 取消并清除
        guard !isIMEActive, isGhostTextEnabled else {
            cancel()
            return
        }

        generation += 1
        let currentGen = generation

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
                guard !Task.isCancelled, self.generation == currentGen else { return }
                self.onRequestGhostText?(currentGen, contextProvider)
            } catch {
                // 任务被取消，静默忽略
            }
        }
    }

    /// 立即取消防抖计时器（用户 Esc 或编辑器失焦）
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
    }
}
