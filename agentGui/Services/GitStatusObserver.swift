// agentGui/Services/GitStatusObserver.swift
import Foundation

// MARK: - GitStatusObserving

/// GitStatusObserver 的可测试协议接口。
/// 参考 Zed：RepositoryEvent::StatusesChanged 让 project_panel 订阅，
/// 此处改为主动拉取模式（push-pull hybrid）。
protocol GitStatusObserving: AnyObject {
    /// 启动观察：立即触发一次状态采集，并在此后每次文件系统变更后重采（300ms 节流）。
    /// - Parameters:
    ///   - rootURL: 仓库根目录 URL（传给 GitService）
    ///   - onUpdate: 状态字典回调，在 MainActor 上调用
    func start(rootURL: URL, onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void)
    /// 停止观察，取消后台任务。
    func stop()
}

// MARK: - GitStatusObserver

/// 真实实现：使用 GitService 拉取 Git 状态，用独立 FSEventObserver 触发重采。
/// 节流窗口 300ms，避免 FSEvent 连续触发导致频繁 git 命令。
@MainActor
final class GitStatusObserver: GitStatusObserving {
    private let gitService: GitServicing
    private let fsObserver: FSEventObserving
    private var debounceTask: Task<Void, Never>?

    /// - Parameters:
    ///   - gitService: 可注入 mock，便于测试。默认使用真实 GitService。
    ///   - fsObserver: 可注入 mock FSEvent 监听器。默认使用真实 FSEventObserver。
    init(gitService: GitServicing? = nil,
         fsObserver: FSEventObserving? = nil) {
        self.gitService = gitService ?? GitService()
        self.fsObserver = fsObserver ?? FSEventObserver()
    }

    func start(rootURL: URL, onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void) {
        stop()

        // 立即采集一次
        Task { @MainActor [weak self] in
            await self?.fetchAndNotify(rootURL: rootURL, onUpdate: onUpdate)
        }

        // 启动 FSEvent 监听（触发节流重采）
        let weakSelf = WeakRef(self)
        Task { @MainActor in
            await self.fsObserver.startObserving(directory: rootURL) { [weak weakSelf] _ in
                Task { @MainActor in
                    guard let observer = weakSelf?.value else { return }
                    observer.scheduleRefresh(rootURL: rootURL, onUpdate: onUpdate)
                }
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        Task { @MainActor in
            await self.fsObserver.stopObserving()
        }
    }

    deinit {
        debounceTask?.cancel()
    }

    // MARK: - Private

    private func scheduleRefresh(rootURL: URL,
                                 onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.fetchAndNotify(rootURL: rootURL, onUpdate: onUpdate)
        }
    }

    private func fetchAndNotify(rootURL: URL,
                                onUpdate: @escaping @MainActor ([URL: GitSummary]) -> Void) async {
        guard let snapshot = try? await gitService.repositorySnapshot(for: rootURL) else { return }
        let statuses = snapshot.changesAsGitSummaryMap()
        onUpdate(statuses)
    }
}

// MARK: - WeakRef（用于跨 Task 弱引用）

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - GitRepositorySnapshot 扩展

extension GitRepositorySnapshot {
    /// 将 `stagedChanges + unstagedChanges + untrackedChanges` 转为 `[URL: GitSummary]` 映射。
    /// 多个变更状态取优先级最高（rawValue 最小）。
    ///
    /// 参考 Zed git_status_indicator 优先级映射（project_panel.rs）。
    func changesAsGitSummaryMap() -> [URL: GitSummary] {
        var result: [URL: GitSummary] = [:]

        func merge(_ change: GitFileChange, summary: GitSummary) {
            if let existing = result[change.absoluteURL] {
                result[change.absoluteURL] = min(existing, summary)
            } else {
                result[change.absoluteURL] = summary
            }
        }

        for change in stagedChanges {
            let summary: GitSummary = change.status == .added ? .added : .staged
            merge(change, summary: summary)
        }
        for change in unstagedChanges {
            let summary: GitSummary = change.status == .deleted ? .deleted : .modified
            merge(change, summary: summary)
        }
        for change in untrackedChanges {
            merge(change, summary: .untracked)
        }

        return result
    }
}
