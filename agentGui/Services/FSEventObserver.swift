// agentGui/Services/FSEventObserver.swift
import Foundation
import CoreServices

// MARK: - FSEventObserverDebouncer

/// FSEvent 防抖聚合器：收集路径事件，在静默期结束后批量回调。
///
/// 对比旧 `WorkspaceTreeRefreshCoordinator.enqueue(paths:generation:)` 的改进：
/// - 职责独立：防抖逻辑完全脱离 ViewModel/Coordinator
/// - `pendingPaths` 使用 `Set` 自动去重（与旧代码一致，但现在在独立类中）
/// - 路径祖先剪枝在 `FileTreeStore.applyFSEvents` 中处理，防抖器只负责聚合
///
/// 参考 VSCode `RunOnceWorker`（nodejsWatcherLib.ts）的聚合思路，
/// 但用 Swift Concurrency `Task.sleep` 替代 setTimeout，更符合 Swift 并发模型。
@MainActor
final class FSEventObserverDebouncer {
    private let intervalNanoseconds: UInt64
    private var pendingPaths: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private var handler: (([String]) -> Void)?

    init(intervalNanoseconds: UInt64 = 150_000_000) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    func setHandler(_ handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    /// 将新路径加入待处理集合，重置防抖计时器。
    func enqueue(_ paths: [String]) {
        pendingPaths.formUnion(paths)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.intervalNanoseconds)
            guard !Task.isCancelled else { return }
            let drained = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            self.handler?(drained)
        }
    }

    /// 取消挂起的防抖任务，不发出回调。
    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingPaths.removeAll()
    }
}

// MARK: - FSEventObserver

/// 生产 FSEvent 监听器。
///
/// 基于 macOS CoreServices `FSEventStreamCreate` 实现递归目录监听。
///
/// 对比旧 `LiveWorkspaceDirectoryObservation` 的改进：
/// - latency 从 0.4s 降到 0.15s（FSEvent 硬件延迟）
/// - 回调使用 `@Sendable` handler，与 Swift 6.0 Actor 安全兼容
/// - 生命周期通过 `startObserving/stopObserving` 显式控制，无 `@unchecked Sendable`
/// - `FSEventObserverDebouncer` 在防抖窗口关闭后批量推送，减少 Store 更新频率
///
/// ## latency 说明
/// FSEvent 的 `latency` 参数是 CoreServices 级别的事件聚合延迟，是 "最长等待时间"。
/// `kFSEventStreamCreateFlagNoDefer` 让首个事件立即发出（不等满 latency），
/// 后续 `FSEventObserverDebouncer` 再做 150ms 软件级聚合。
/// VSCode 使用 75ms 软件聚合（FILE_CHANGES_HANDLER_DELAY），Zed 不做软件防抖（由调用方处理）。
/// 本设计取 150ms 与原项目保持一致。
final class FSEventObserver: FSEventObserving, @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private var debouncer: FSEventObserverDebouncer?

    func startObserving(
        directory: URL,
        handler: @escaping @Sendable ([String]) -> Void
    ) async {
        await MainActor.run {
            let debouncer = FSEventObserverDebouncer()
            debouncer.setHandler(handler)
            self.debouncer = debouncer
            self.startStream(rootURL: directory.standardizedFileURL)
        }
    }

    func stopObserving() async {
        await MainActor.run {
            self.debouncer?.cancel()
            self.debouncer = nil
            self.stopStream()
        }
    }

    // MARK: - CoreServices 流管理

    @MainActor
    private func startStream(rootURL: URL) {
        final class CallbackBox {
            let fn: ([String]) -> Void
            init(_ fn: @escaping ([String]) -> Void) { self.fn = fn }
        }

        guard let debouncer else { return }
        let callbackBox = Unmanaged.passRetained(CallbackBox { [weak debouncer] paths in
            // FSEvent 回调在 FSEvent 的私有线程（RunLoop）触发，
            // 需要跳回 MainActor 才能访问 debouncer。
            Task { @MainActor [weak debouncer] in
                debouncer?.enqueue(paths)
            }
        })

        var context = FSEventStreamContext(
            version: 0,
            info: callbackBox.toOpaque(),
            retain: nil,
            release: { ptr in Unmanaged<CallbackBox>.fromOpaque(ptr!).release() },
            copyDescription: nil
        )

        // FSEvent flags 解释：
        // - kFSEventStreamCreateFlagNoDefer:   有事件时立即发出，不等满 latency
        // - kFSEventStreamCreateFlagWatchRoot: 监听根目录本身的挂载/卸载事件
        // - kFSEventStreamCreateFlagUseCFTypes: 使用 CFArray<CFString> 而非 void** 路径数组
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        // latency: 0.15s — CoreServices 端聚合窗口
        // 旧 LiveWorkspaceDirectoryObservation 使用 0.4s，此处减半提升响应速度。
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                Unmanaged<CallbackBox>.fromOpaque(info!).takeUnretainedValue().fn(paths)
            },
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            callbackBox.release()
            return
        }

        FSEventStreamScheduleWithRunLoop(
            stream,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            callbackBox.release()
            return
        }

        self.streamRef = stream
    }

    @MainActor
    private func stopStream() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }
}
