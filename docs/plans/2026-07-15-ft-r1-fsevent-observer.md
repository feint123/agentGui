# FT-R1：FSEvent 观察器 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 FSEvent 监听从 `WorkspaceTreeRefreshCoordinator` 中解耦为独立、可测试的 `FSEventObserver` 组件，并为 `FileTreeStore` 添加 `applyFSEvents` 增量更新入口。

**Architecture:**
- `FSEventObserving` 协议抽象 FSEvent 监听行为，`MockFSEventObserver` 供测试注入，`FSEventObserver` 为生产实现。
- `FSEventObserver` 基于 macOS CoreServices `FSEventStreamCreate`，将原生回调收集到 `Set<String>` 后通过 Swift `Task.sleep` 防抖 150ms，最终回调 `@Sendable` handler。
- `FileTreeStore.applyFSEvents` 计算受影响目录 → 祖先剪枝 → 逐目录增量刷新（超 30 目录降级全量）。

**Tech Stack:** Swift 6.0+, Foundation, CoreServices (FSEventStreamCreate), XCTest

**参考来源：**
- 旧代码 `WorkspaceTreeRefreshCoordinator.swift`：
  - `LiveWorkspaceDirectoryObservation` — 现有 FSEventStream 创建方式
    (`kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes`，latency 0.4s)
  - `enqueue(paths:generation:)` — Task.sleep 防抖模式
  - `WorkspaceTreeSnapshotOps.refreshTargets(for:rootURL:)` — dirty directory 计算逻辑（移植到 FileTreeStore）
- Zed `crates/fs/src/fs_watcher.rs`：
  - `coalesce_pending_rescans` — 祖先路径剪枝逻辑（子路径被父路径覆盖时丢弃）
  - `extend_sorted` — 有序合并 pending 路径列表
- VSCode `nodejsWatcherLib.ts`：
  - `FILE_CHANGES_HANDLER_DELAY = 75` — 事件聚合延迟（本实现取 150ms，与原项目一致）
  - `ThrottledWorker<IFileChange>` — 节流发射器思路（本实现用 Task.sleep 实现，Swift 并发更简洁）
- 设计文档 `docs/plans/2026-07-15-filetree-rewrite-design.md` §FT-R1

---

## 前置条件

- 已完成 FT-R0（`FileTreeStore.swift` 骨架存在，`FileScanning` 协议已定义）。
- 了解 `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift`：
  - `LiveWorkspaceDirectoryObservation` — 提取 FSEvent 创建方式
  - `WorkspaceTreeSnapshotOps.refreshTargets(for:rootURL:)` — dirty directory 算法参考
- 了解 `openFileRefreshMonitor.swift`（另一个 FSEvent 使用点，作为参考但不改动）

---

## Task 1：`FSEventObserving` 协议 + `MockFSEventObserver`

**Files:**
- Create: `agentGui/Services/FSEventObserving.swift`
- Create: `agentGuiTests/FSEventObserverTests.swift`（先建测试文件）

### Step 1：在测试文件里写第一个 Mock 验证断言

```swift
// agentGuiTests/FSEventObserverTests.swift
import XCTest
@testable import agentGui

final class FSEventObserverTests: XCTestCase {

    // MARK: - MockFSEventObserver

    func testMockObserver_deliversPaths() async {
        let mock = MockFSEventObserver()
        var receivedPaths: [[String]] = []

        await mock.startObserving(directory: URL(fileURLWithPath: "/tmp")) { paths in
            receivedPaths.append(paths)
        }
        await mock.simulateEvents(["/tmp/foo.txt", "/tmp/bar.txt"])

        XCTAssertEqual(receivedPaths.count, 1)
        XCTAssertEqual(Set(receivedPaths[0]), ["/tmp/foo.txt", "/tmp/bar.txt"])
    }

    func testMockObserver_stopObserving_silencesEvents() async {
        let mock = MockFSEventObserver()
        var receivedCount = 0

        await mock.startObserving(directory: URL(fileURLWithPath: "/tmp")) { _ in
            receivedCount += 1
        }
        await mock.stopObserving()
        await mock.simulateEvents(["/tmp/foo.txt"])

        XCTAssertEqual(receivedCount, 0)
    }
}
```

### Step 2：运行测试，预期编译失败（`MockFSEventObserver` 不存在）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FSEventObserverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`error: cannot find type 'MockFSEventObserver'`

### Step 3：实现 `FSEventObserving.swift`

```swift
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
```

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FSEventObserverTests/testMockObserver_deliversPaths \
  -only-testing:agentGuiTests/FSEventObserverTests/testMockObserver_stopObserving_silencesEvents \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FSEventObserving.swift agentGuiTests/FSEventObserverTests.swift
git commit -m "FT-R1 task1: FSEventObserving protocol + MockFSEventObserver"
```

---

## Task 2：防抖逻辑测试 + `FSEventObserver` 防抖骨架

**Files:**
- Modify: `agentGuiTests/FSEventObserverTests.swift`（追加防抖测试）
- Create: `agentGui/Services/FSEventObserver.swift`（骨架，仅防抖逻辑，暂不接 CoreServices）

### Step 1：追加防抖测试

```swift
// 追加到 agentGuiTests/FSEventObserverTests.swift
// MARK: - FSEventObserver debounce（内部防抖单元测试）

func testDebounceAggregator_coalescesPaths() async {
    // FSEventObserverDebouncer 是 FSEventObserver 内部的防抖聚合器。
    // 我们单独提取以便白盒测试——无需真实 FSEvent 流。
    let debouncer = FSEventObserverDebouncer(intervalNanoseconds: 50_000_000) // 50ms

    var received: [[String]] = []
    debouncer.setHandler { paths in
        received.append(paths)
    }

    // 快速推送3批事件，50ms 内
    debouncer.enqueue(["/tmp/a.txt"])
    debouncer.enqueue(["/tmp/b.txt"])
    debouncer.enqueue(["/tmp/a.txt"])  // 重复路径

    // 等待防抖窗口结束（100ms > 50ms）
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(received.count, 1, "3 rapid enqueues should be coalesced into 1 callback")
    XCTAssertEqual(Set(received[0]), ["/tmp/a.txt", "/tmp/b.txt"],
                   "Duplicate paths should be deduplicated")
}

func testDebounceAggregator_cancelPreventsCallback() async {
    let debouncer = FSEventObserverDebouncer(intervalNanoseconds: 100_000_000) // 100ms
    var callbackCount = 0
    debouncer.setHandler { _ in callbackCount += 1 }

    debouncer.enqueue(["/tmp/a.txt"])
    debouncer.cancel()

    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(callbackCount, 0, "Cancelled debouncer should not fire")
}
```

### Step 2：运行测试，预期编译失败（`FSEventObserverDebouncer` 不存在）

### Step 3：实现 `FSEventObserver.swift`（防抖骨架，暂无 CoreServices）

```swift
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

    // CoreServices 流创建（Task 2 实现 stub，Task 3 填充真实代码）
    @MainActor
    private func startStream(rootURL: URL) {
        // 真实 FSEventStream 创建见 Task 3
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
```

> **设计说明：**
> `FSEventObserver` 标注 `@unchecked Sendable` 的理由与旧 `LiveWorkspaceDirectoryObservation`
> 相同：`FSEventStreamRef` 是 C 核心类型，无法自动 `Sendable`。
> 但访问 `streamRef` 的路径全部在 `@MainActor` 中，实际线程安全。

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FSEventObserverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FSEventObserver.swift agentGuiTests/FSEventObserverTests.swift
git commit -m "FT-R1 task2: FSEventObserverDebouncer + FSEventObserver skeleton"
```

---

## Task 3：`FSEventObserver` CoreServices 实现

**Files:**
- Modify: `agentGui/Services/FSEventObserver.swift`（填充 `startStream` 的真实逻辑）

### Step 1：实现 `startStream`（完整 CoreServices 代码）

将 `FSEventObserver.startStream` 替换为以下实现：

```swift
// 替换 FSEventObserver 中的 startStream 方法
@MainActor
private func startStream(rootURL: URL) {
    // 使用 Unmanaged 持有持有 weak self 的回调盒，避免循环引用。
    // 参考旧 LiveWorkspaceDirectoryObservation.start(rootURL:onChange:) 的模式，
    // 但显式管理 debouncer 的线程安全（均在 @MainActor）。
    final class CallbackBox {
        let fn: ([String]) -> Void
        init(_ fn: @escaping ([String]) -> Void) { self.fn = fn }
    }

    guard let debouncer else { return }
    let callbackBox = Unmanaged.passRetained(CallbackBox { [weak debouncer] paths in
        // FSEvent 回调在 FSEvent 的私有线程（RunLoop）触发，
        // 需要跳回 MainActor 才能访问 debouncer。
        // 参考旧代码：WorkspaceTreeRefreshCoordinator 在此用 Task { @MainActor }
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
    // - kFSEventStreamCreateFlagNoDefer:   有事件时立即发出，不等满 latency（减少延迟）
    // - kFSEventStreamCreateFlagWatchRoot: 监听根目录本身的挂载/卸载事件
    // - kFSEventStreamCreateFlagUseCFTypes: 使用 CFArray<CFString> 而非 void** 路径数组
    //
    // VSCode 同样监控 /Volumes 下目录会拒绝（网络共享不稳定），此处暂不处理（FT-R1 作用域外）。
    let flags: FSEventStreamCreateFlags =
        UInt32(kFSEventStreamCreateFlagNoDefer) |
        UInt32(kFSEventStreamCreateFlagWatchRoot) |
        UInt32(kFSEventStreamCreateFlagUseCFTypes)

    // latency: 0.15s — CoreServices 端聚合窗口（与设计文档 debounceInterval 一致）
    // 旧 LiveWorkspaceDirectoryObservation 使用 0.4s，此处减半提升响应速度。
    // 注意：latency 是 CoreServices 内部聚合，FSEventObserverDebouncer 在其后再做 150ms 软件聚合，
    // 总延迟 ≈ 0ms（首路径立即到达 debouncer）到 150ms（debouncer 等待静默）。
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

    // 挂到 main RunLoop 的 default mode，与旧实现一致。
    // 注意：kFSEventStreamCreateFlagUseCFTypes 要求在 RunLoop 上调度。
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
```

> **与旧代码对比：**
> - 旧 latency `0.4` → 新 `0.15`（reduce from 400ms to 150ms coreside aggregation）
> - 旧 `FSEventStreamEventId.max`（仅历史）→ 新 `kFSEventStreamEventIdSinceNow`（仅当前时刻起）
> - 回调内用 `Task { @MainActor }` 显式切回主线程，比旧代码 `Task { @MainActor in self.enqueue }` 更清晰

### Step 2：验证编译通过（无新测试，Task 2 的测试已覆盖接口）

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** BUILD SUCCEEDED **`

### Step 3：提交

```bash
git add agentGui/Services/FSEventObserver.swift
git commit -m "FT-R1 task3: FSEventObserver CoreServices implementation"
```

---

## Task 4：`FileTreeStore.computeDirtyDirectories` + `pruneDescendants`

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`（添加两个 static 辅助方法）
- Create: `agentGuiTests/FileTreeStoreFSEventTests.swift`（新测试文件）

### Step 1：先写测试

```swift
// agentGuiTests/FileTreeStoreFSEventTests.swift
import XCTest
@testable import agentGui

final class FileTreeStoreFSEventTests: XCTestCase {

    // MARK: - computeDirtyDirectories

    func testComputeDirtyDirectories_returnsParentsOfChangedFiles() {
        let rootURL = URL(fileURLWithPath: "/repo")
        let paths = [
            "/repo/src/main.swift",
            "/repo/tests/unit/FooTests.swift"
        ]
        let result = FileTreeStore.computeDirtyDirectories(paths, rootURL: rootURL)

        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/src")))
        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/tests/unit")))
    }

    func testComputeDirtyDirectories_excludesPathsOutsideRoot() {
        let rootURL = URL(fileURLWithPath: "/repo")
        let paths = ["/other/project/file.swift", "/repo/main.swift"]
        let result = FileTreeStore.computeDirtyDirectories(paths, rootURL: rootURL)

        let paths = result.map(\.path)
        XCTAssertFalse(paths.contains("/other/project"))
        XCTAssertTrue(paths.contains("/repo"))
    }

    func testComputeDirtyDirectories_changedDirectoryIncludesItself() {
        let rootURL = URL(fileURLWithPath: "/repo")
        // 如果变更路径本身就是目录（e.g. 新目录创建），它自己也应被标记为 dirty
        let paths = ["/repo/src/NewDir"]  // 假设 IsDirectory = true
        let result = FileTreeStore.computeDirtyDirectories(paths, rootURL: rootURL)

        XCTAssertTrue(result.contains(URL(fileURLWithPath: "/repo/src")))
    }

    // MARK: - pruneDescendants

    func testPruneDescendants_removesChildWhenParentPresent() {
        let dirs = [
            URL(fileURLWithPath: "/repo/src"),
            URL(fileURLWithPath: "/repo/src/utils"),          // 子路径
            URL(fileURLWithPath: "/repo/src/utils/helpers"),  // 孙路径
            URL(fileURLWithPath: "/repo/tests"),
        ]
        let pruned = FileTreeStore.pruneDescendants(dirs)

        XCTAssertTrue(pruned.contains(URL(fileURLWithPath: "/repo/src")))
        XCTAssertTrue(pruned.contains(URL(fileURLWithPath: "/repo/tests")))
        XCTAssertFalse(pruned.contains(URL(fileURLWithPath: "/repo/src/utils")),
                       "Child of /repo/src should be pruned")
        XCTAssertFalse(pruned.contains(URL(fileURLWithPath: "/repo/src/utils/helpers")),
                       "Grandchild of /repo/src should be pruned")
    }

    func testPruneDescendants_keepsUnrelatedSiblings() {
        let dirs = [
            URL(fileURLWithPath: "/a/b"),
            URL(fileURLWithPath: "/a/c"),  // sibling, NOT child of /a/b
        ]
        let pruned = FileTreeStore.pruneDescendants(dirs)

        XCTAssertEqual(Set(pruned.map(\.path)), ["/a/b", "/a/c"])
    }
}
```

### Step 2：运行，预期编译失败（`FileTreeStore.computeDirtyDirectories` 不存在）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`error: type 'FileTreeStore' has no member 'computeDirtyDirectories'`

### Step 3：在 `FileTreeStore.swift` 中添加 static 辅助方法

在 `FileTreeStore` actor 定义内追加以下 `nonisolated static` 方法（纯函数，无 actor state 依赖，方便测试直接调用）：

```swift
// 在 actor FileTreeStore 内部追加

// MARK: - FSEvent 增量更新辅助（对外暴露 static 供测试）

/// 根据 FSEvent 变更路径计算需要重新扫描的目录集合。
///
/// 算法（参考旧 `WorkspaceTreeSnapshotOps.refreshTargets(for:rootURL:)`）：
/// 1. 文件变更 → 取父目录
/// 2. 目录变更（isDirectory = true）→ 取自身
/// 3. 只保留 rootURL 树内的路径
///
/// 注意：此方法不进行 I/O（不 stat 路径），依赖已知条件，轻量快速。
nonisolated static func computeDirtyDirectories(
    _ changedPaths: [String],
    rootURL: URL
) -> [URL] {
    let rootStandardized = rootURL.standardizedFileURL
    let rootPath = rootStandardized.path
    var dirty = Set<URL>()

    for path in changedPaths {
        let changedURL = URL(fileURLWithPath: path).standardizedFileURL
        let parentURL = changedURL.deletingLastPathComponent()

        // 父目录若在 root 树下，标记为 dirty
        let parentPath = parentURL.path
        if parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") {
            dirty.insert(parentURL)
        }

        // 变更路径本身若是目录（目录被创建/删除），标记自身
        // 注意：此处仅根据路径特征判断（无 stat），目录形态会在 refreshDirectory 中确认
        let changedPath = changedURL.path
        if changedPath.hasPrefix(rootPath + "/") || changedPath == rootPath {
            dirty.insert(changedURL)
        }
    }

    // 按路径深度排序（浅层先处理），让后续 pruneDescendants 保留最浅的祖先
    return Array(dirty).sorted { $0.path.count < $1.path.count }
}

/// 剪枝：若一个路径已有祖先在集合中，则移除该路径。
///
/// 算法参考 Zed `coalesce_pending_rescans` 的祖先覆盖逻辑：
/// - 若父目录在列表中，子目录的刷新隐含在父目录刷新中，可丢弃
/// - 减少不必要的 shallowScan 调用
nonisolated static func pruneDescendants(_ directories: [URL]) -> [URL] {
    var result: [URL] = []
    for dir in directories {
        let dirPath = dir.standardizedFileURL.path
        let coveredByAncestor = result.contains { ancestor in
            let ancestorPath = ancestor.standardizedFileURL.path
            return dirPath != ancestorPath && dirPath.hasPrefix(ancestorPath + "/")
        }
        if !coveredByAncestor {
            result.append(dir)
        }
    }
    return result
}
```

> **与旧代码对比：**
> - 旧 `WorkspaceTreeSnapshotOps.refreshTargets` 是全局静态函数，接收 `URL` 数组。
> - 新方法挂在 `FileTreeStore` 上，`nonisolated static`，保持可测试性同时语义更聚焦。
> - `pruneDescendants` 对应 Zed `coalesce_pending_rescans` 中父路径覆盖子路径的逻辑，
>   Zed 处理 `Rescan` 事件，本实现处理 dirty directory 集合，逻辑等价。

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FileTreeStore.swift agentGuiTests/FileTreeStoreFSEventTests.swift
git commit -m "FT-R1 task4: FileTreeStore computeDirtyDirectories + pruneDescendants"
```

---

## Task 5：`FileTreeStore.applyFSEvents` + `refreshDirectory`

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`（添加公开方法）
- Modify: `agentGuiTests/FileTreeStoreFSEventTests.swift`（追加集成测试）

### Step 1：追加测试（使用 Task 4 中建立的 MockFileScanner + MockFileTreeStoreDelegate）

```swift
// 追加到 FileTreeStoreFSEventTests.swift

// MARK: - applyFSEvents 集成测试

/// 测试 applyFSEvents 使用 MockFileScanner，
/// 能感知到目录内容变化并更新 Store。
func testApplyFSEvents_refreshesDirtyDirectory() async throws {
    // 使用 FT-R0 中定义的 MockFileScanner
    // 初始状态：/repo 包含 [src/, README.md]
    let scanner = MockFileScanner()
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src"), name: "src", isDirectory: true),
        ScannedEntry(url: URL(fileURLWithPath: "/repo/README.md"), name: "README.md", isDirectory: false),
    ])
    scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src/main.swift"), name: "main.swift", isDirectory: false),
    ])

    let store = FileTreeStore(scanner: scanner)
    await store.setRoot(URL(fileURLWithPath: "/repo"))

    // 模拟 FSEvent：src 目录内新增文件
    scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src/main.swift"), name: "main.swift", isDirectory: false),
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src/utils.swift"), name: "utils.swift", isDirectory: false),
    ])

    await store.applyFSEvents(["/repo/src/utils.swift"])

    let visible = await store.computeVisibleEntries(searchFilter: nil, searchMode: .filter)
    let names = visible.map(\.name)
    XCTAssertTrue(names.contains("utils.swift"), "New file should appear after applyFSEvents")
}

func testApplyFSEvents_prunesDescendantPaths() async throws {
    var scannedDirs: [URL] = []
    let scanner = MockFileScanner()
    scanner.onShallowScan = { dir in scannedDirs.append(dir) }
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src"), name: "src", isDirectory: true),
    ])
    scanner.stub(directory: URL(fileURLWithPath: "/repo/src"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/src/utils"), name: "utils", isDirectory: true),
    ])
    scanner.stub(directory: URL(fileURLWithPath: "/repo/src/utils"), entries: [])

    let store = FileTreeStore(scanner: scanner)
    await store.setRoot(URL(fileURLWithPath: "/repo"))
    // 先展开 src 和 src/utils
    await store.expandDirectory(EntryID(url: URL(fileURLWithPath: "/repo/src")))
    await store.expandDirectory(EntryID(url: URL(fileURLWithPath: "/repo/src/utils")))

    scannedDirs.removeAll()

    // 同时触发 src 和 src/utils 的变更——src/utils 应被剪枝
    await store.applyFSEvents(["/repo/src/foo.swift", "/repo/src/utils/bar.swift"])

    // src/utils 被 src 覆盖，不应独立重扫
    let scannedPaths = scannedDirs.map(\.path)
    XCTAssertTrue(scannedPaths.contains("/repo/src"), "src should be rescanned")
    // src/utils 若 src 重扫后会以子树形式更新，不需单独重扫
    XCTAssertFalse(scannedPaths.contains("/repo/src/utils"),
                   "src/utils is covered by src rescan, should be pruned")
}

func testApplyFSEvents_degradesToFullReloadWhenTooManyChanges() async throws {
    var fullReloadCount = 0
    let scanner = MockFileScanner()
    scanner.onShallowScan = { _ in fullReloadCount += 1 }
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [])

    let store = FileTreeStore(scanner: scanner)
    await store.setRoot(URL(fileURLWithPath: "/repo"))
    fullReloadCount = 0  // reset after setRoot

    // 触发超过 30 个不同目录的变更
    let manyPaths = (1...35).map { "/repo/dir\($0)/file.swift" }
    for i in 1...35 {
        scanner.stub(
            directory: URL(fileURLWithPath: "/repo/dir\(i)"),
            entries: []
        )
    }

    await store.applyFSEvents(manyPaths)

    // 降级为全量重建：扫描 root 一次
    XCTAssertGreaterThan(fullReloadCount, 0, "Should fall back to full reload")
}
```

### Step 2：运行，预期编译失败（`applyFSEvents` 方法不存在）

### Step 3：在 `FileTreeStore.swift` 中添加 `applyFSEvents` + `refreshDirectory`

```swift
// 在 actor FileTreeStore 内追加

// MARK: - FSEvent 增量更新

/// FSEvent 回调入口：根据变更路径增量更新 Store 状态。
///
/// 算法（参考设计文档 §3.2 + 旧 WorkspaceTreeRefreshCoordinator.refresh）：
/// 1. 计算 dirty 目录集合（变更路径的父目录）
/// 2. 祖先剪枝（子路径被父路径覆盖时移除）
/// 3. 若剪枝后目录数 > 30 → 降级为 setRoot 全量重建
/// 4. 否则逐一 refreshDirectory
///
/// - Parameter changedPaths: FSEvent 回调的原始路径字符串数组
func applyFSEvents(_ changedPaths: [String]) async {
    guard let rootURL else { return }

    let dirty = Self.computeDirtyDirectories(changedPaths, rootURL: rootURL)
    let pruned = Self.pruneDescendants(dirty)

    if pruned.count > 30 {
        // 降级：超过 30 个受影响目录，全量重建成本低于逐个刷新
        await setRoot(rootURL)
        return
    }

    for dir in pruned {
        await refreshDirectory(dir)
    }
}

/// 重新扫描单个目录，将结果与 Store 中现有子条目对比，增量更新。
///
/// 对比旧 `WorkspaceTreeSnapshotOps.applyPartialUpdate`：
/// - 旧：在递归树结构上执行，O(深度 × 宽度)
/// - 新：直接操作 `children` 邻接表，O(孩子数)
private func refreshDirectory(_ url: URL) async {
    let dirID = EntryID(url: url.standardizedFileURL)

    // 只对已知且已展开的目录执行增量刷新
    guard entries[dirID] != nil else {
        // 目录不在 Store 中（可能是新目录），尝试插入父目录的子条目
        let parent = url.deletingLastPathComponent()
        let parentID = EntryID(url: parent.standardizedFileURL)
        if entries[parentID] != nil {
            await refreshDirectory(parent)
        }
        return
    }

    // 重新扫描
    guard let scanned = try? await scanner.shallowScan(directory: url) else { return }

    let existingChildren = Set(children[dirID] ?? [])
    var newChildren: [EntryID] = []

    for item in scanned {
        let itemID = EntryID(url: item.url.standardizedFileURL)
        newChildren.append(itemID)

        if entries[itemID] == nil {
            // 新出现的条目
            entries[itemID] = FileEntry(
                id: itemID,
                name: item.name,
                isDirectory: item.isDirectory,
                parentID: dirID
            )
        }
    }

    // 删除已消失的条目及其子树
    let newChildSet = Set(newChildren)
    for removed in existingChildren.subtracting(newChildSet) {
        removeSubtree(rooted: removed)
    }

    children[dirID] = sortedChildren(newChildren)
    // 更新父目录 loadState
    if var entry = entries[dirID] {
        entry.loadState = .loaded
        entries[dirID] = entry
    }
}

/// 递归删除某 entryID 及其所有子孙条目。
private func removeSubtree(rooted id: EntryID) {
    if let childIDs = children.removeValue(forKey: id) {
        for child in childIDs {
            removeSubtree(rooted: child)
        }
    }
    entries.removeValue(forKey: id)
    expandedIDs.remove(id)
}

/// 对子条目按"目录优先，名字字母序"排序，与旧 WorkspaceTreeSnapshotOps 排序规则一致。
private func sortedChildren(_ ids: [EntryID]) -> [EntryID] {
    ids.sorted { lhs, rhs in
        let lEntry = entries[lhs]
        let rEntry = entries[rhs]
        let lIsDir = lEntry?.isDirectory ?? false
        let rIsDir = rEntry?.isDirectory ?? false
        if lIsDir != rIsDir { return lIsDir }
        let lName = lEntry?.name ?? lhs.url.lastPathComponent
        let rName = rEntry?.name ?? rhs.url.lastPathComponent
        return lName.localizedCaseInsensitiveCompare(rName) == .orderedAscending
    }
}
```

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FileTreeStore.swift agentGuiTests/FileTreeStoreFSEventTests.swift
git commit -m "FT-R1 task5: FileTreeStore.applyFSEvents + refreshDirectory"
```

---

## Task 6：`FileTreeStore` 集成 `FSEventObserver`

**Files:**
- Modify: `agentGui/Services/FileTreeStore.swift`（添加 `fsObserver` 属性，在 `setRoot` 中启动）
- Modify: `agentGuiTests/FileTreeStoreFSEventTests.swift`（追加端到端集成测试）

### Step 1：追加端到端测试

```swift
// 追加到 FileTreeStoreFSEventTests.swift

// MARK: - FSEventObserver 集成

func testStore_withMockObserver_receivesSimulatedEvents() async throws {
    let scanner = MockFileScanner()
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/main.swift"), name: "main.swift", isDirectory: false),
    ])

    let mockObserver = MockFSEventObserver()
    let store = FileTreeStore(scanner: scanner, fsObserver: mockObserver)
    await store.setRoot(URL(fileURLWithPath: "/repo"))

    // 模拟新文件出现
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [
        ScannedEntry(url: URL(fileURLWithPath: "/repo/main.swift"), name: "main.swift", isDirectory: false),
        ScannedEntry(url: URL(fileURLWithPath: "/repo/helper.swift"), name: "helper.swift", isDirectory: false),
    ])

    // 通过 Mock 触发 FSEvent
    await mockObserver.simulateEvents(["/repo/helper.swift"])

    // 等待 Store 处理（applyFSEvents 是 async）
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

    let visible = await store.computeVisibleEntries(searchFilter: nil, searchMode: .filter)
    let names = visible.map(\.name)
    XCTAssertTrue(names.contains("helper.swift"),
                  "Store should reflect new file after MockFSEventObserver triggers")
}

func testStore_setDirectory_nil_stopsObserver() async throws {
    let scanner = MockFileScanner()
    scanner.stub(directory: URL(fileURLWithPath: "/repo"), entries: [])

    let mockObserver = MockFSEventObserver()
    let store = FileTreeStore(scanner: scanner, fsObserver: mockObserver)
    await store.setRoot(URL(fileURLWithPath: "/repo"))

    XCTAssertTrue(await mockObserver.isObserving, "Observer should be active after setRoot")

    await store.clearRoot()  // 清除 root
    XCTAssertFalse(await mockObserver.isObserving, "Observer should stop when root is cleared")
}
```

### Step 2：运行，预期编译失败（`fsObserver` 参数不存在）

### Step 3：修改 `FileTreeStore`，注入 `FSEventObserving`

```swift
// 修改 actor FileTreeStore 的属性和 init

actor FileTreeStore {
    // ── 已有属性 ──
    private var entries: [EntryID: FileEntry] = [:]
    private var children: [EntryID: [EntryID]] = [:]
    private var rootIDs: [EntryID] = []
    private var expandedIDs: Set<EntryID> = []
    private var rootURL: URL?

    private let scanner: FileScanning
    private let fsObserver: FSEventObserving   // ← 新增

    init(
        scanner: FileScanning = RealFileScanner(),
        fsObserver: FSEventObserving = FSEventObserver()  // ← 新增
    ) {
        self.scanner = scanner
        self.fsObserver = fsObserver
    }

    // setRoot 中添加观察启动逻辑：
    func setRoot(_ url: URL) async {
        // 停止旧观察
        await fsObserver.stopObserving()

        rootURL = url.standardizedFileURL
        entries.removeAll()
        children.removeAll()
        rootIDs.removeAll()
        expandedIDs.removeAll()

        // 扫描根目录
        // ... 已有扫描逻辑 ...

        // 启动新观察
        let rootForCapture = self.rootURL!
        await fsObserver.startObserving(directory: rootForCapture) { [weak self] changedPaths in
            Task { [weak self] in
                await self?.applyFSEvents(changedPaths)
            }
        }
    }

    // 新增：clearRoot
    func clearRoot() async {
        await fsObserver.stopObserving()
        rootURL = nil
        entries.removeAll()
        children.removeAll()
        rootIDs.removeAll()
    }
}
```

> **Swift Concurrency 注意点：**
> `fsObserver.startObserving(directory:handler:)` 中的 handler 是 `@Sendable` 闭包，
> 在非 actor 的后台线程被调用（FSEvent RunLoop 回调）。
> 闭包内用 `Task { [weak self] in await self?.applyFSEvents(changedPaths) }` 安全切回 actor。
> 与旧 `WorkspaceTreeRefreshCoordinator.setDirectory` 中
> `Task { @MainActor [weak self] in self?.enqueue(paths:generation:) }` 模式对应。

### Step 4：运行测试，验证通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 5：提交

```bash
git add agentGui/Services/FileTreeStore.swift agentGuiTests/FileTreeStoreFSEventTests.swift
git commit -m "FT-R1 task6: FileTreeStore integrates FSEventObserver via protocol"
```

---

## Task 7：运行全部 FT-R1 相关测试，验收

### Step 1：运行 FSEventObserverTests + FileTreeStoreFSEventTests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r1-derived \
  -only-testing:agentGuiTests/FSEventObserverTests \
  -only-testing:agentGuiTests/FileTreeStoreFSEventTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case|session)"
```

预期：所有测试通过，无 `FAILED` 行。

### Step 2：验证不影响现有 FileTreeStore 的 FT-R0 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-ft-r1-derived \
  -only-testing:agentGuiTests/FileTreeStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`

### Step 3：最终提交标签

```bash
git tag ft-r1-complete
```

---

## 测试覆盖总结

| 文件 | 测试 | 覆盖点 |
|------|------|--------|
| `FSEventObserverTests` | `testMockObserver_deliversPaths` | Mock 基本回调 |
| `FSEventObserverTests` | `testMockObserver_stopObserving_silencesEvents` | Stop 后不回调 |
| `FSEventObserverTests` | `testDebounceAggregator_coalescesPaths` | 多路径合并 + 去重 |
| `FSEventObserverTests` | `testDebounceAggregator_cancelPreventsCallback` | 取消不回调 |
| `FileTreeStoreFSEventTests` | `testComputeDirtyDirectories_returnsParentsOfChangedFiles` | dirty 计算基本逻辑 |
| `FileTreeStoreFSEventTests` | `testComputeDirtyDirectories_excludesPathsOutsideRoot` | root 过滤 |
| `FileTreeStoreFSEventTests` | `testComputeDirtyDirectories_changedDirectoryIncludesItself` | 目录自身标记 |
| `FileTreeStoreFSEventTests` | `testPruneDescendants_removesChildWhenParentPresent` | 祖先剪枝 |
| `FileTreeStoreFSEventTests` | `testPruneDescendants_keepsUnrelatedSiblings` | 不剪枝兄弟节点 |
| `FileTreeStoreFSEventTests` | `testApplyFSEvents_refreshesDirtyDirectory` | 单目录增量刷新 |
| `FileTreeStoreFSEventTests` | `testApplyFSEvents_prunesDescendantPaths` | 端到端剪枝验证 |
| `FileTreeStoreFSEventTests` | `testApplyFSEvents_degradesToFullReloadWhenTooManyChanges` | > 30 目录降级 |
| `FileTreeStoreFSEventTests` | `testStore_withMockObserver_receivesSimulatedEvents` | FSEvent → Store 端到端 |
| `FileTreeStoreFSEventTests` | `testStore_setDirectory_nil_stopsObserver` | clearRoot 停止监听 |

**估计代码量：** ~200 行产品代码 + ~250 行测试代码

---

## 不在 FT-R1 范围内（推迟到后续批次）

- `FileTreeViewModel` 订阅 Store 变更（FT-R2）
- NSTableView 渲染（FT-R2）
- `.gitignore` 排除（FT-R6）
- 对 `/Volumes/` 网络共享的拒绝监听（VSCode 的 isMacintosh && /Volumes/ 检查）
- 监听符号链接目标目录（类似 Zed `read_link` 逻辑）
