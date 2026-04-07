# FT-P2 实现计划：后台增量排序去重

日期：2026-04-07  
关联设计文档：[2026-04-07-filetree-iteration-design.md](./2026-04-07-filetree-iteration-design.md)  
优先级：P3（FT-P1 完成后评估）

---

## 一、问题描述

### 现象

执行 `git checkout`、`git stash pop`、批量代码生成等操作时，FSEvents 会在同一个 150ms 防抖窗口内触发大量路径变更通知（50～1000+ 个路径）。现有 `WorkspaceTreeRefreshCoordinator` 的处理路径如下：

```
FSEvent batch
  → pendingPaths.formUnion(paths)           // Set 去重（已有）
  → 150ms 防抖到期
  → refresh(paths:generation:)              // @MainActor
      → refreshTargets(for:rootURL:)        // 计算脏目录集合（同步在 MainActor）
      → Task.detached {
            for dir in refreshTargets {      // 串行逐个更新
                applyPartialUpdate(…)        // 每次从根遍历整棵树
            }
        }
```

### 两个核心问题

**问题 1：`refreshTargets` 缺少祖先支配裁剪**

假设 `git checkout` 改动了 `src/a/x.swift`、`src/b/y.swift`、`src/a/z.swift`：

- 当前计算结果：`[src/a/, src/b/]`（正确）
- 但若同时改动了 `src/`（本身是目录变化，如新增文件），则结果为：`[src/, src/a/, src/b/]`
- 当前排序策略：按路径字符串**长度**排（`src/` 先处理）
- 问题：`applyPartialUpdate(nodes, src/a/)` 和 `applyPartialUpdate(nodes, src/b/)` 仍然各做一次完整树遍历，而 `src/` 的更新**已经**刷新过 `src/` 这层。但 `applyPartialUpdate` 实现是：仅刷新精确匹配 `targetURL` 的目录节点，**不递归刷新子目录**——so `src/a/` 确实需要单独刷新。

> **真正的浪费发生在**：同一路径下有大量同级叶目录，每个 `applyPartialUpdate` 调用都从根开始遍历整棵已加载树，复杂度为 O(N × D)，其中 N 是脏目录数量，D 是树的深度。对于有 100 个脏目录的大型项目，这是 100 次完整树遍历。

**问题 2：`refreshTargets` 和路径计算在 MainActor 同步执行**

`refresh(paths:generation:)` 是 `@MainActor` 上的 `async` 函数，`refreshTargets(for:rootURL:)` 在其中同步调用。虽然该函数通常很快，但在极端情况（1000+ 路径）下会短暂阻塞 UI 线程。

---

## 二、参考来源

### Zed `process_events`（`crates/worktree/src/worktree.rs`）

Zed 在处理 FS 事件时采用 **Sort + 祖先支配 dedup** 两步：

```rust
// Step 1: 排序（路径按字典序，确保祖先在子孙之前）
events.sort_unstable_by(|left, right| left.path.cmp(&right.path));

// Step 2: 祖先支配裁剪
// 若 left.path 以 right.path 为前缀（即 left 是 right 的子孙）→ 合并
events.dedup_by(|left, right| {
    if left.path == right.path {
        // 完全相同路径，合并 Rescan 语义
        ...
        true
    } else if left.path.starts_with(&right.path) {
        // left 是 right 的后代，right 的刷新已经覆盖 left
        ...
        true
    } else {
        false
    }
});
```

注意：`dedup_by` 在 Rust 中对相邻元素比较；字典序排序保证了 `/a/b` 总是排在 `/a/` **之后**，故 `starts_with` 检查只需看相邻对。

### VSCode `_refreshInternally`（`explorerModel.ts`）

VSCode 对 Explorer 的批量更新同样采用"找最浅公共父级"策略：给定一组变更路径，只对它们最近的共同祖先目录做一次 `refreshLocal`，减少重复刷新。

---

## 三、设计方案

### 3.1 核心改动：`refreshTargets` 添加祖先支配裁剪

在现有 `refreshTargets(for:rootURL:)` 的最后，在返回前增加一个 **sort + dedup** 步骤：

```swift
// 当前（仅按路径长度排序）：
return dirtyDirectories.sorted { $0.path.count < $1.path.count }

// 改为（字典序排序 + 祖先支配裁剪）：
let sorted = dirtyDirectories.sorted { $0.path < $1.path } // 字典序
return pruneDescendants(sorted)
```

`pruneDescendants` 算法（O(N log N) 排序 + O(N) 扫描）：

```swift
/// 给定已按字典序排序的目录 URL 数组，移除所有「其路径以某个已保留路径为前缀」的条目。
/// 字典序排序保证祖先（如 /src/）始终排在其后代（如 /src/a/）之前，
/// 故只需线性扫描：若当前路径以上一个保留路径开头，则跳过。
static func pruneDescendants(_ sorted: [URL]) -> [URL] {
    var result: [URL] = []
    result.reserveCapacity(sorted.count)
    for url in sorted {
        let path = url.path
        if let last = result.last {
            let lastPath = last.path
            // 若 path == lastPath+"/..." 则是后代，跳过
            if path.hasPrefix(lastPath + "/") || path == lastPath {
                continue
            }
        }
        result.append(url)
    }
    return result
}
```

> **正确性保证**：字典序下，`/src/` < `/src/a/` < `/src/b/`（因为 `/src/` < `/src/a`），因此祖先总在后代之前出现。线性扫描检查 `hasPrefix(lastPath + "/")` 即可安全过滤所有后代。

### 3.2 大批量回退：超阈值时降级为根节点全量刷新

`git checkout` 等操作可能产生跨多个不共享公共祖先的脏目录（例如同时修改 `src/`、`tests/`、`docs/`）。祖先支配裁剪无法减少这类情况，此时继续做 N 次独立树遍历不如做一次根级 `shallowScan + mergeNodes`。

在 `refresh(paths:generation:)` 的 `Task.detached` 区块内：

```swift
// 裁剪后的 refreshTargets
let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: drainedPaths, rootURL: rootURL)

// 大批量阈值（30 个）：超阈值退化为根级合并
let effectiveTargets: [URL]
if targets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold {
    effectiveTargets = [rootURL]   // 仅刷新根节点 1 层
} else {
    effectiveTargets = targets
}
```

阈值常量 `largeRefreshThreshold = 30`，可通过 `AppSettings` 或构造参数调整（单测可注入）。

### 3.3 将 `refreshTargets` 计算移入后台任务

当前 `refresh(paths:generation:)` 在 `@MainActor` 上调用 `WorkspaceTreeSnapshotOps.refreshTargets`（纯 CPU 计算，无 IO）。在路径数量极大时（> 500 个路径字符串）有 UI 卡顿风险。

改动：将 `refreshTargets` 调用从 MainActor 移入已存在的 `Task.detached` 块：

```swift
// 之前（MainActor 上计算）：
private func refresh(paths: [String], generation: Int) async {
    let refreshTargets = WorkspaceTreeSnapshotOps.refreshTargets(...)  // MainActor
    scanTask = Task.detached { ... }
}

// 之后（后台计算）：
private func refresh(paths: [String], generation: Int) async {
    let snapshot = currentNodes
    let rootURL = currentDirectory!
    scanTask = Task.detached(priority: .utility) { [weak self] in
        // 1. 计算脏目录（后台）
        let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: rootURL)
        guard !targets.isEmpty else { return }
        
        // 2. 大批量检测
        let effectiveTargets = targets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold
            ? [rootURL]
            : targets
        
        // 3. 逐目录刷新（已有逻辑）
        var updated = snapshot
        for targetURL in effectiveTargets {
            guard !Task.isCancelled else { return }
            ...
        }
        ...
    }
}
```

---

## 四、涉及文件与变更清单

| 文件 | 变更类型 | 说明 |
|---|---|---|
| `agentGui/Utilities/WorkspaceTreeRefreshCoordinator.swift` | 修改 | （1）`refreshTargets` 改为字典序排序 + 祖先支配裁剪；（2）`largeRefreshThreshold` 常量；（3）将 `refreshTargets` 调用移入 `Task.detached` |
| `agentGuiTests/WorkspaceTreeRefreshTargetsPruningTests.swift` | 新增 | 覆盖祖先裁剪逻辑的单测 |

> 不涉及 `FileNode.swift`、ViewModel 层、View 层，变更范围极小。

---

## 五、`WorkspaceTreeSnapshotOps` 具体 diff

### 5.1 新增 `pruneDescendants`（纯静态函数，放在 `refreshTargets` 下方）

```swift
// MARK: - FT-P2: 祖先支配裁剪

/// 字典序排序后，移除「路径前缀被已保留条目覆盖」的后代 URL。
/// 输入必须已按路径字典序排序。复杂度 O(N)。
static func pruneDescendants(_ sorted: [URL]) -> [URL] {
    var result: [URL] = []
    result.reserveCapacity(sorted.count)
    for url in sorted {
        let path = url.path
        if let lastPath = result.last?.path,
           path == lastPath || path.hasPrefix(lastPath + "/") {
            continue   // 后代，跳过
        }
        result.append(url)
    }
    return result
}

/// 大批量阈值：超过此数量的脏目录时，降级为根级全量合并。
static let largeRefreshThreshold = 30
```

### 5.2 修改 `refreshTargets`

```swift
// 原实现末尾：
return dirtyDirectories.sorted { $0.path.count < $1.path.count }

// 改为：
let sorted = dirtyDirectories.sorted { $0.path < $1.path }  // 字典序
return pruneDescendants(sorted)
```

### 5.3 修改 `refresh(paths:generation:)` — 将计算移入后台

```swift
private func refresh(paths: [String], generation: Int) async {
    guard generation == self.generation, let rootURL = currentDirectory else { return }

    let snapshot = currentNodes
    guard !snapshot.isEmpty else {
        scheduleFullReload(for: rootURL, generation: generation)
        return
    }

    let shallowScan = shallowScanClosure
    let mergeNodes = mergeNodesClosure
    let applyPartialUpdate = applyPartialUpdateClosure
    let rootURLCopy = rootURL

    scanTask?.cancel()
    scanTask = Task.detached(priority: .utility) { [weak self] in   // ← priority 降为 .utility（计算密集型）
        // 1. 后台计算脏目录（FT-P2 新增：原在 MainActor 上计算）
        let rawTargets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: rootURLCopy)
        guard !rawTargets.isEmpty else { return }

        // 2. 大批量降级（FT-P2 新增）
        let targets: [URL] = rawTargets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold
            ? [rootURLCopy]
            : rawTargets

        // 3. 串行刷新（已有逻辑，无变化）
        var updated = snapshot
        for targetURL in targets {
            guard !Task.isCancelled else { return }
            if targetURL == rootURLCopy {
                let freshScan = await shallowScan(rootURLCopy)
                updated = await mergeNodes(updated, freshScan)
            } else {
                updated = await applyPartialUpdate(updated, targetURL)
            }
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard let self,
                  self.generation == generation,
                  self.currentDirectory == rootURLCopy else { return }
            self.currentNodes = updated
            self.onNodesChanged?(updated, false)
        }
    }
}
```

---

## 六、测试计划

新增测试文件：`agentGuiTests/WorkspaceTreeRefreshTargetsPruningTests.swift`

### 6.1 `pruneDescendants` 单元测试

| 测试用例 | 输入 | 期望输出 |
|---|---|---|
| 无后代，保持原样 | `[/a, /b, /c]` | `[/a, /b, /c]` |
| 有后代，裁剪 | `[/src, /src/a, /src/b]` | `[/src]` |
| 混合：部分有后代 | `[/docs, /src, /src/a, /tests]` | `[/docs, /src, /tests]` |
| 三层嵌套 | `[/a, /a/b, /a/b/c]` | `[/a]` |
| 完全相同路径 | `[/a, /a]` | `[/a]` |
| 空输入 | `[]` | `[]` |
| 单个元素 | `[/a]` | `[/a]` |

### 6.2 `refreshTargets` 集成测试

```swift
@Test func refreshTargetsPrunesDescendants() {
    let root = URL(fileURLWithPath: "/project")
    // 模拟 git checkout 改动 src/ 下多个文件
    let paths = [
        "/project/src/a/x.swift",
        "/project/src/a/y.swift",
        "/project/src/b/z.swift",
        "/project/src/c.swift",    // src/ 下直接文件
    ]
    let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
    // src/a/, src/b/ 都是 src/ 的后代，若 src/ 本身是脏目录则应被裁剪
    // 本例中 src/ 下的直接文件 c.swift 导致 src/ 进入脏集合
    // src/a/ 和 src/b/ 是 src/ 的后代 → 裁剪后只剩 [src/]
    #expect(targets == [URL(fileURLWithPath: "/project/src")])
}

@Test func refreshTargetsKeepsIndependentDirs() {
    let root = URL(fileURLWithPath: "/project")
    let paths = [
        "/project/src/a.swift",
        "/project/tests/b.swift",
    ]
    let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: paths, rootURL: root)
    // src/ 和 tests/ 互不包含 → 两者都保留
    #expect(targets.count == 2)
    #expect(targets.contains(URL(fileURLWithPath: "/project/src")))
    #expect(targets.contains(URL(fileURLWithPath: "/project/tests")))
}
```

### 6.3 大批量回退测试

```swift
@Test func largeRefreshFallsBackToRoot() async throws {
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ft-p2-large-\(Int.random(in: 1000...9999))")
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    // 创建 35 个子目录，每个下面有 1 个文件
    for i in 0..<35 {
        let subdir = tmpRoot.appendingPathComponent("dir\(i)")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try "file".write(to: subdir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    }

    var refreshCallCount = 0
    let coordinator = WorkspaceTreeRefreshCoordinator(
        observationFactory: .init { _, _ in nil },
        applyPartialUpdate: { nodes, url in
            refreshCallCount += 1
            return WorkspaceTreeSnapshotOps.applyPartialUpdate(to: nodes, at: url)
        }
    )

    coordinator.setDirectory(tmpRoot)
    try await Task.sleep(nanoseconds: 300_000_000)

    // 模拟 35 个不同目录下各改动一个文件（共 35 个脏目录 > 阈值 30）
    let fakePaths = (0..<35).map { i in
        tmpRoot.appendingPathComponent("dir\(i)/file.txt").path
    }
    // 直接调用 refreshDirectories 验证降级行为
    let targets = WorkspaceTreeSnapshotOps.refreshTargets(for: fakePaths, rootURL: tmpRoot)
    // 35 个脏目录 > largeRefreshThreshold(30)，协调器应降级为刷新根节点
    #expect(targets.count > WorkspaceTreeSnapshotOps.largeRefreshThreshold)
    // 实际 refresh 中会取 [rootURL]，故 applyPartialUpdate 调用 0 次，走 mergeNodes 路径
}
```

### 6.4 回归测试：FSEvent 反压（背压）不变

验证已有的 `scanTask?.cancel()` 策略在新实现下仍然生效：快速连发两批 FSEvent 时，第一批的 `Task.detached` 被第二批取消。

```swift
@Test func consecutiveRefreshCancelsPreviousTask() async throws {
    // 验证：两次快速变更，最终只有一次 onNodesChanged 被调用（最后一次）
    // 此测试已被现有 WorkspaceTreeDemandLoadCoordinatorTests 中的行为间接覆盖
    // 需在新文件中补充针对 refresh() 路径的显式取消测试
}
```

---

## 七、性能预期

| 场景 | 改进前 | 改进后 |
|---|---|---|
| `git checkout`（100 个脏目录） | 100 次 `applyPartialUpdate` | ≤ 1 次 `mergeNodes(root)`（大批量降级） |
| 小改动（2 个兄弟目录） | 2 次树遍历 | 2 次树遍历（不变） |
| 嵌套改动（父 + 子同时脏） | 2 次树遍历（含冗余子目录遍历） | 1 次树遍历（祖先支配裁剪） |
| 单文件保存 | 1 次树遍历 | 1 次树遍历（不变） |
| MainActor 占用（1000 个 FSEvent 路径） | 同步计算阻塞 UI 线程 ~1ms | 后台计算，主线程 0 开销 |

---

## 八、设计约束确认

1. **不破坏 FSEvent → debounce → applyPartialUpdate 链路**：`pendingPaths` 积累和 150ms 防抖逻辑不变，仅改变防抖到期后的处理策略。
2. **背压（backpressure）不变**：`scanTask?.cancel()` 策略保持，新旧任务在同一 `scanTask` 变量上管理。
3. **generation 校验不变**：Task 完成后的 `self.generation == generation` 检验逻辑不变，防止过时刷新写入当前节点。
4. **懒加载兼容**：`applyPartialUpdate` 对 `.notLoaded` 节点的处理（直接 return，等待用户展开触发 `demandLoad`）逻辑不变。
5. **`Task` 优先级调整**：原 `Task.detached(priority: .userInitiated)` 改为 `.utility`，因为 FSEvent 刷新不需要与用户输入同等优先级（`demandLoad` 仍保持 `.userInitiated`）。
6. **Swift 6 Actor 隔离**：`refreshTargets` 是静态纯函数（`Sendable`），放入后台 Task 无 Actor 隔离问题；`rootURL`/`paths` 作为值类型参数按值传入，符合 Swift 6 并发规则。

---

## 九、执行顺序

1. **步骤 1**：在 `WorkspaceTreeSnapshotOps` 中新增 `pruneDescendants` + `largeRefreshThreshold`，修改 `refreshTargets` 返回值（纯逻辑，无 IO，可先单独测试）
2. **步骤 2**：修改 `refresh(paths:generation:)`，将 `refreshTargets` 调用移入 `Task.detached`（优先级改为 `.utility`），添加大批量降级
3. **步骤 3**：新增测试文件 `WorkspaceTreeRefreshTargetsPruningTests.swift`
4. **步骤 4**：运行现有 `WorkspaceTreeDemandLoadCoordinatorTests` 回归验证

预计改动量：`WorkspaceTreeRefreshCoordinator.swift` 约 +30 / -5 行。
