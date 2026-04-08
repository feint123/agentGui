// agentGui/Services/FSEventObserving.swift
import Foundation

// MARK: - FSEventObserving

/// FSEvent 监听协议。
///
/// 生产实现：`FSEventObserver`（CoreServices FSEventStream）
/// 测试替身：`MockFSEventObserver`（内存实现，可手动触发事件）
///
/// 对比旧 `WorkspaceDirectoryObservationFactory`：
/// - 旧：通过闭包工厂注入，语义不清晰，不支持 async 控制
/// - 新：协议 + actor 替身，接口清晰，Swift Concurrency 原生
protocol FSEventObserving: Sendable {
    /// 开始监听指定目录的变更。
    ///
    /// - Parameters:
    ///   - directory: 要监听的根目录 URL。
    ///   - handler: 当文件变更时回调，传入变更路径列表。
    ///             在后台线程被调用（非 @MainActor）。
    func startObserving(
        directory: URL,
        handler: @escaping @Sendable ([String]) -> Void
    ) async

    /// 停止监听，释放底层 FSEventStream 资源。
    func stopObserving() async
}

// MARK: - MockFSEventObserver

/// 测试替身：手动触发 FSEvent 回调，不依赖磁盘。
///
/// 设计参考 Zed `FakeFs.emit_fs_event`：
/// - 允许测试精确控制事件时机，消除 FSEvent 内核延迟的不确定性
/// - `simulateEvents` 直接调用回调，不走防抖（防抖在 FSEventObserver 中，Mock 不需要）
actor MockFSEventObserver: FSEventObserving {
    private var handler: (@Sendable ([String]) -> Void)?
    private(set) var isObserving = false
    private(set) var observedDirectory: URL?

    func startObserving(
        directory: URL,
        handler: @escaping @Sendable ([String]) -> Void
    ) async {
        self.handler = handler
        self.observedDirectory = directory
        self.isObserving = true
    }

    func stopObserving() async {
        handler = nil
        isObserving = false
    }

    /// 测试专用：手动推送一批变更路径，立即回调。
    func simulateEvents(_ paths: [String]) async {
        guard isObserving, let handler else { return }
        handler(paths)
    }
}
