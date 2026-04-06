# R-C3 RewindPreflightInspector Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `RewindPreflightInspector` 服务，在用户触发回滚之前异步预检查目标 `ConversationCheckpoint` 会影响哪些文件，供确认 UI（R-D2）展示变化摘要和三选项恢复菜单。

**Architecture:** `RewindPreflightInspector` 是一个 `actor`，依赖 `FileBackupStore`. 它暴露两个公开方法：轻量布尔检查 `hasAnyFileChanges`（早退，只 stat 不 diff）和完整摘要计算 `computeDiffStats`（并发对每个追踪文件调用 `StructuredDiffEngine`）。与 `FileSystemRewindCoordinator` 共享 `FileBackupStore` 依赖，彼此独立不耦合。

**Tech Stack:** Swift 6, SwiftData, `FileBackupStore`（R-A2，已实现），`StructuredDiffEngine`（已实现），`ProposedFileChangeKind`（已有枚举），Swift Testing framework (`import Testing`)。

---

## 背景与依赖说明

### 已实现的依赖

| 类型 | 文件 | 用途 |
|------|------|------|
| `ConversationCheckpoint` (@Model) | `agentGui/Models/ConversationCheckpoint.swift` | 快照元数据，含 `trackedFileBackupsJSON`、`sessionID`、`workspaceRoot` |
| `FileBackupEntry` | 同上 | 单文件备份元数据：`backupKey`、`version`、`originalRelativePath` |
| `FileBackupStore` (actor) | `agentGui/Services/Rewind/FileBackupStore.swift` | `hasFileChanged(filePath:sessionID:entry:)` → Bool；备份文件读取 |
| `StructuredDiffEngine` | `agentGui/Services/ChangeReview/StructuredDiffEngine.swift` | `build(relativePath:absolutePath:kind:baseContent:stagedContent:)` → `StructuredFileDiff` |
| `StructuredFileDiff` / `DiffSummary` | `agentGui/Services/ChangeReview/StructuredDiffTypes.swift` | `summary.additions`、`summary.deletions` |
| `ProposedFileChangeKind` | `agentGui/Models/ProposedFileChange.swift` | `.add` / `.modify` / `.delete` |

### diff 逻辑说明

`StructuredDiffEngine.build` 需要 `baseContent`（备份内容，即回滚目标）和 `stagedContent`（当前文件内容）。从 R-C3 角度：
- **baseContent** = 备份文件内容（`~/.agentgui/checkpoints/{sessionID}/{key[:2]}/{key}.bak`）
- **stagedContent** = 工作区当前文件内容

对于 `backupKey == nil` 的文件（快照时文件不存在）：
- 若文件现在存在 → `kind = .delete`（回滚后会被删除），`baseContent = nil`，`stagedContent = 当前内容`
- 回滚方向注意：`insertions`/`deletions` 语义是"从当前到备份"，即"回滚后新增了什么行"。对于预览，保持与 Claude Code `computeDiffStatsForFile` 一致：insertions = 备份比当前**多**的行数，deletions = 当前比备份**多**的行数。

对于文件在快照时存在，但现在不存在（已被删除）：
- `kind = .add`（回滚后会被恢复出来），`baseContent = 备份内容`，`stagedContent = nil`

### relativePath → absolutePath 规则

与 `FileSystemRewindCoordinator` 保持一致：

```swift
func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
    relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
}
```

### 测试框架

项目使用 **Swift Testing**（`import Testing`，`@Test`，`#expect`，`@Suite`），
测试文件在 `agentGuiTests/`，无需 `XCTestCase` 继承。
参考已有测试：`FileSystemRewindCoordinatorTests.swift`。

---

## Task 1：定义 `RewindDiffStats` + 创建空壳 `RewindPreflightInspector.swift`

**Files:**
- Create: `agentGui/Services/Rewind/RewindPreflightInspector.swift`

### Step 1: 创建空壳文件（含类型定义）

```swift
// agentGui/Services/Rewind/RewindPreflightInspector.swift
import Foundation

// MARK: - RewindDiffStats

/// 回滚预检查结果，供确认 UI 展示变化摘要。
struct RewindDiffStats: Sendable, Equatable {
    /// 将被恢复（内容有差异）的文件绝对路径列表。
    var filesChanged: [String]

    /// 行级别统计：回滚后相对于当前状态新增的行数。
    var totalInsertions: Int

    /// 行级别统计：回滚后相对于当前状态删除的行数。
    var totalDeletions: Int

    /// 将被删除的文件（这些文件在快照时不存在，但现在存在；回滚后会被删除）。
    var addedFiles: [String]

    /// 将被恢复的文件（这些文件在快照时存在，但现在已被删除；回滚后会被重新创建）。
    var deletedFiles: [String]

    /// 内容被修改的文件（快照时存在，现在存在，但内容不同）。
    var modifiedFiles: [String]

    /// 便利构造器：空统计（无变化）
    static let empty = RewindDiffStats(
        filesChanged: [],
        totalInsertions: 0,
        totalDeletions: 0,
        addedFiles: [],
        deletedFiles: [],
        modifiedFiles: []
    )
}

// MARK: - RewindPreflightInspector

/// R-C3: 在用户触发回滚之前，异步计算回滚影响预览数据。
///
/// ## 两种操作模式
/// - `hasAnyFileChanges(checkpoint:)` — 轻量布尔检查，只 stat 不 diff，早退。用于决定是否显示确认对话框。
/// - `computeDiffStats(checkpoint:)` — 完整 diff 统计，并发对每个文件调用 StructuredDiffEngine，用于填充确认对话框。
///
/// ## 并发安全
/// `actor` 隔离；内部文件 IO 通过 `fileBackupStore`（另一个 actor）执行。
actor RewindPreflightInspector: Sendable {

    // MARK: - Dependencies

    private let fileBackupStore: FileBackupStore

    // MARK: - Init

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API (stubs — 后续 Task 填充)

    /// 轻量检查：回滚到此检查点是否会改变任何文件。
    /// 对每个被追踪文件调用 `FileBackupStore.hasFileChanged`，早退于第一个有变化的文件。
    /// 无文件变化时耗时 < 10ms（纯 stat，不读文件内容）。
    func hasAnyFileChanges(
        checkpoint: ConversationCheckpoint
    ) async throws -> Bool {
        fatalError("Not implemented")
    }

    /// 完整统计：计算回滚此检查点会产生多少行变化，涉及哪些文件。
    /// 并发对每个追踪文件调用 StructuredDiffEngine，返回聚合统计。
    func computeDiffStats(
        checkpoint: ConversationCheckpoint
    ) async throws -> RewindDiffStats {
        fatalError("Not implemented")
    }
}
```

### Step 2: 确认文件可编译（会 crash，但需通过编译）

在 Xcode 中 Build（Cmd+B），确认无编译错误（`fatalError` 是合法占位符）。

---

## Task 2：实现 `hasAnyFileChanges`

**Files:**
- Modify: `agentGui/Services/Rewind/RewindPreflightInspector.swift`

### Step 1: 编写失败测试

创建测试文件 `agentGuiTests/RewindPreflightInspectorTests.swift`，先只写 `hasAnyFileChanges` 的测试：

```swift
// agentGuiTests/RewindPreflightInspectorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Test Helpers

@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 在内存 ModelContext 中插入一个 ConversationCheckpoint
@MainActor
private func makeCheckpoint(
    sessionID: String,
    workspaceRoot: String,
    entries: [String: FileBackupEntry],
    in ctx: ModelContext
) throws -> ConversationCheckpoint {
    let cp = try ConversationCheckpoint(
        sessionID: sessionID,
        messageID: UUID(),
        snapshotSequence: 0,
        workspaceRoot: workspaceRoot,
        trackedFileBackups: entries,
        hasFileChanges: !entries.isEmpty
    )
    ctx.insert(cp)
    return cp
}

// MARK: - Suite

@MainActor
@Suite("RewindPreflightInspector Tests")
struct RewindPreflightInspectorTests {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - hasAnyFileChanges

    /// 无追踪文件的空检查点 → hasAnyFileChanges = false
    @Test
    func hasAnyFileChanges_emptyCheckpoint_returnsFalse() async throws {
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let inspector = RewindPreflightInspector(fileBackupStore: store)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: "s1",
            workspaceRoot: workspaceRoot,
            entries: [:],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == false)
    }

    /// 文件内容与备份相同 → hasAnyFileChanges = false
    @Test
    func hasAnyFileChanges_fileUnchanged_returnsFalse() async throws {
        let sessionID = "s-unchanged-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // 创建文件并备份
        let filePath = workspaceRoot + "/foo.txt"
        try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["foo.txt": entry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == false)
    }

    /// 文件内容被修改 → hasAnyFileChanges = true
    @Test
    func hasAnyFileChanges_fileModified_returnsTrue() async throws {
        let sessionID = "s-modified-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/bar.txt"
        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 模拟 agent 修改文件
        try "modified by agent".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["bar.txt": entry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }

    /// backupKey == nil，文件现在存在 → hasAnyFileChanges = true（快照时文件不存在，现在存在）
    @Test
    func hasAnyFileChanges_nilBackupFileNowExists_returnsTrue() async throws {
        let sessionID = "s-nilback-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // nil backupKey = 快照时文件不存在
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: "new.txt"
        )

        // 但现在文件存在（由 agent 创建）
        let filePath = workspaceRoot + "/new.txt"
        try "created by agent".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["new.txt": nilEntry],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }

    /// 早退验证：多个文件中第一个有变化，不继续检查后续文件（行为验证：仍返回 true，非性能测试）
    @Test
    func hasAnyFileChanges_earlyExitOnFirstChanged() async throws {
        let sessionID = "s-earlyexit-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // 两个文件，第一个已修改，第二个未修改
        let file1 = workspaceRoot + "/a.txt"
        let file2 = workspaceRoot + "/b.txt"
        try "original-a".write(toFile: file1, atomically: true, encoding: .utf8)
        try "original-b".write(toFile: file2, atomically: true, encoding: .utf8)
        let entry1 = try await store.createBackup(filePath: file1, sessionID: sessionID, version: 1)
        let entry2 = try await store.createBackup(filePath: file2, sessionID: sessionID, version: 1)

        // 修改 a.txt
        try "modified-a".write(toFile: file1, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [
                "a.txt": entry1,
                "b.txt": entry2
            ],
            in: ctx
        )

        let result = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
        #expect(result == true)
    }
}
```

### Step 2: 运行测试，确认全部失败（fatalError）

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc3-derived \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:|fatalError"
```

预期：测试失败（`fatalError: Not implemented`）或无法编译。

### Step 3: 实现 `hasAnyFileChanges`

将 `RewindPreflightInspector.swift` 中的 `hasAnyFileChanges` stub 替换为：

```swift
func hasAnyFileChanges(
    checkpoint: ConversationCheckpoint
) async throws -> Bool {
    let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

    // 空检查点 → 无变化
    guard !trackedFileBackups.isEmpty else { return false }

    for (relativePath, entry) in trackedFileBackups {
        let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)
        let changed = await fileBackupStore.hasFileChanged(
            filePath: absPath,
            sessionID: checkpoint.sessionID,
            entry: entry
        )
        if changed { return true }  // 早退
    }

    return false
}
```

在文件末尾添加私有辅助方法（与 `FileSystemRewindCoordinator` 保持一致）：

```swift
// MARK: - Private Helpers

private extension RewindPreflightInspector {
    func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
    }
}
```

> **注意：** `private extension` 写在 actor 的大括号**外部**，不在 `actor` 声明内，与 Swift 的 extension 语法一致。

### Step 4: 运行 `hasAnyFileChanges` 测试，确认全部通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc3-derived \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Suite.*passed|Suite.*failed|Test.*passed|Test.*failed"
```

预期：5 个测试全部 passed（`computeDiffStats` 的测试此时尚未加入）。

### Step 5: Commit

```bash
git add agentGui/Services/Rewind/RewindPreflightInspector.swift \
        agentGuiTests/RewindPreflightInspectorTests.swift
git commit -m "feat(rewind): R-C3 RewindPreflightInspector — add hasAnyFileChanges with early-exit"
```

---

## Task 3：实现 `computeDiffStats`

**Files:**
- Modify: `agentGui/Services/Rewind/RewindPreflightInspector.swift`
- Modify: `agentGuiTests/RewindPreflightInspectorTests.swift`

### 核心逻辑说明（阅读后再写代码）

对每个被追踪的 `(relativePath, entry)` 对：

| 场景 | `backupKey` | 当前文件 | `kind` | `baseContent` | `stagedContent` | 归入 |
|------|------------|---------|--------|--------------|----------------|------|
| 文件被 agent 修改 | non-nil | 存在 | `.modify` | 备份内容 | 当前内容 | `modifiedFiles`（若有 diff）|
| 文件由 agent 新增（回滚后删除）| nil | 存在 | `.delete` | nil | 当前内容 | `addedFiles` |
| 文件被 agent 删除（回滚后恢复）| non-nil | 不存在 | `.add` | 备份内容 | nil | `deletedFiles` |
| 文件未变化 | non-nil | 存在，内容同备份 | — | — | — | 跳过（不计入 filesChanged）|

**diff 方向语义（与 Claude Code 对齐）：**
- `StructuredDiffEngine.build` 中，第一个参数 `baseContent` 对应"旧版本（backup）"，`stagedContent` 对应"新版本（当前）"。
- `summary.additions` = 当前文件比备份**多**的行数（回滚后这些行会消失，即"deletions"在用户视角）
- `summary.deletions` = 备份比当前**多**的行数（回滚后这些行会出现，即"insertions"在用户视角）
- 对于 `totalInsertions` / `totalDeletions` 字段，按 Claude Code `fileHistoryGetDiffStats` 的惯例：`insertions` = 备份比当前多、`deletions` = 当前比备份多，即 `insertions += summary.deletions`，`deletions += summary.additions`。
  > 原因：Claude Code 的 diff 是 "current → backup"（恢复视角），additions = 回滚后新增的行，removals = 回滚后删除的行。与 `diffLines(currentContent, backupContent)` 的 `added/removed` 语义对齐。

**读取备份文件内容：**

`FileBackupStore` 没有公开"读取备份内容"的方法，需要在 `RewindPreflightInspector` 内部通过备份文件路径直接读取，或者在 `FileBackupStore` 上添加一个辅助方法。

**推荐：** 在 `FileBackupStore` 上新增：

```swift
// 在 FileBackupStore 中添加
func backupFileURL(backupKey: String, sessionID: String) -> URL {
    let shard = String(backupKey.prefix(2))
    return checkpointsBaseURL
        .appendingPathComponent(sessionID)
        .appendingPathComponent(shard)
        .appendingPathComponent("\(backupKey).bak")
}
```

> **注意：** `backupURL(backupKey:sessionID:)` 已存在但是 `private`，需要将其公开或添加公开包装。检查 `FileBackupStore.swift` 的访问级别再决定是直接改 `private` → `package`/`internal`，还是新增公开方法。

### Step 1: 在 `FileBackupStore` 添加路径读取辅助

打开 `agentGui/Services/Rewind/FileBackupStore.swift`，在 `// MARK: - Public API` 区块末尾（`deleteBackups` 之后，`// MARK: - Internal Path Helpers` 之前）添加：

```swift
/// 读取备份文件内容（文本）。若备份文件不存在或无法读取，返回 nil。
/// 用于 RewindPreflightInspector 计算 diff stats。
func readBackupContent(backupKey: String, sessionID: String) async -> String? {
    let url = backupURL(backupKey: backupKey, sessionID: sessionID)
    return try? String(contentsOf: url, encoding: .utf8)
}
```

### Step 2: 编写 `computeDiffStats` 测试（追加到 `RewindPreflightInspectorTests.swift`）

在测试文件的 `@Suite` 末尾（最后一个 `@Test` 函数之后的 `}` 之前）追加：

```swift
    // MARK: - computeDiffStats

    /// 空检查点 → 空统计
    @Test
    func computeDiffStats_emptyCheckpoint_returnsEmpty() async throws {
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)
        let inspector = RewindPreflightInspector(fileBackupStore: store)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: "s-empty",
            workspaceRoot: workspaceRoot,
            entries: [:],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)
        #expect(stats == RewindDiffStats.empty)
    }

    /// 文件内容被修改 → modifiedFiles 包含该文件，totalInsertions/Deletions 反映行差异
    @Test
    func computeDiffStats_modifiedFile_correctStats() async throws {
        let sessionID = "s-diff-modified-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/edit.txt"
        // 备份内容：2 行
        let originalContent = "line1\nline2\n"
        try originalContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 当前内容：3 行（新增 line3，修改 line1）
        let currentContent = "LINE1\nline2\nline3\n"
        try currentContent.write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["edit.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.modifiedFiles.count == 1)
        #expect(stats.addedFiles.isEmpty)
        #expect(stats.deletedFiles.isEmpty)
        #expect(stats.filesChanged.count == 1)
        // 总行变化 > 0
        #expect(stats.totalInsertions + stats.totalDeletions > 0)
    }

    /// backupKey == nil，文件现在存在 → addedFiles 包含该文件（回滚后会被删除）
    @Test
    func computeDiffStats_newFileCreatedByAgent_inAddedFiles() async throws {
        let sessionID = "s-diff-added-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        // nil backupKey = 快照时文件不存在
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: "created.txt"
        )

        // 文件现在存在（由 agent 创建）
        let filePath = workspaceRoot + "/created.txt"
        try "new content".write(toFile: filePath, atomically: true, encoding: .utf8)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["created.txt": nilEntry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.addedFiles.contains(filePath))
        #expect(stats.filesChanged.contains(filePath))
        #expect(stats.modifiedFiles.isEmpty)
        #expect(stats.deletedFiles.isEmpty)
    }

    /// 文件被 agent 删除（backupKey non-nil，文件现在不存在）→ deletedFiles 包含该文件
    @Test
    func computeDiffStats_fileDeletedByAgent_inDeletedFiles() async throws {
        let sessionID = "s-diff-deleted-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/willdelete.txt"
        try "content before delete".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        // 模拟 agent 删除文件
        try FileManager.default.removeItem(atPath: filePath)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["willdelete.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats.deletedFiles.contains(filePath))
        #expect(stats.filesChanged.contains(filePath))
        #expect(stats.modifiedFiles.isEmpty)
        #expect(stats.addedFiles.isEmpty)
    }

    /// 文件未变化 → filesChanged 为空
    @Test
    func computeDiffStats_unchangedFile_notInFilesChanged() async throws {
        let sessionID = "s-diff-unchanged-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBase = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBase)

        let filePath = workspaceRoot + "/unchanged.txt"
        try "no changes".write(toFile: filePath, atomically: true, encoding: .utf8)
        let entry = try await store.createBackup(filePath: filePath, sessionID: sessionID, version: 1)

        let inspector = RewindPreflightInspector(fileBackupStore: store)
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["unchanged.txt": entry],
            in: ctx
        )

        let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)

        #expect(stats == RewindDiffStats.empty)
    }
```

### Step 3: 运行测试，确认 `computeDiffStats` 测试失败

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc3-derived \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed"
```

预期：hasAnyFileChanges 的 5 个测试仍 passed，computeDiffStats 的 5 个测试 failed（fatalError）。

### Step 4: 实现 `computeDiffStats`

将 `RewindPreflightInspector.swift` 中的 `computeDiffStats` stub 替换为完整实现：

```swift
func computeDiffStats(
    checkpoint: ConversationCheckpoint
) async throws -> RewindDiffStats {
    let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

    guard !trackedFileBackups.isEmpty else { return .empty }

    let diffEngine = StructuredDiffEngine()

    // 并发对每个文件计算 diff（withThrowingTaskGroup 以异步并发方式运行）
    var perFileResults: [(RewindFileResult)] = []

    await withTaskGroup(of: RewindFileResult?.self) { group in
        for (relativePath, entry) in trackedFileBackups {
            group.addTask {
                await self.computeFileResult(
                    relativePath: relativePath,
                    entry: entry,
                    checkpoint: checkpoint,
                    diffEngine: diffEngine
                )
            }
        }
        for await result in group {
            if let r = result {
                perFileResults.append(r)
            }
        }
    }

    // 聚合结果
    var filesChanged: [String] = []
    var totalInsertions = 0
    var totalDeletions = 0
    var addedFiles: [String] = []
    var deletedFiles: [String] = []
    var modifiedFiles: [String] = []

    for r in perFileResults {
        filesChanged.append(r.absolutePath)
        totalInsertions += r.insertions
        totalDeletions += r.deletions
        switch r.category {
        case .added:    addedFiles.append(r.absolutePath)
        case .deleted:  deletedFiles.append(r.absolutePath)
        case .modified: modifiedFiles.append(r.absolutePath)
        }
    }

    return RewindDiffStats(
        filesChanged: filesChanged,
        totalInsertions: totalInsertions,
        totalDeletions: totalDeletions,
        addedFiles: addedFiles,
        deletedFiles: deletedFiles,
        modifiedFiles: modifiedFiles
    )
}
```

在 `actor RewindPreflightInspector` 内部添加私有辅助类型和方法：

```swift
// MARK: - Private Helpers (inside actor body)

private enum FileChangeCategory {
    case added    // 快照时不存在，现在存在 → 回滚后会被删除
    case deleted  // 快照时存在，现在不存在 → 回滚后会被恢复
    case modified // 快照时存在，现在也存在，但内容不同
}

private struct RewindFileResult {
    let absolutePath: String
    let insertions: Int   // 回滚后新增的行数（备份比当前多的行）
    let deletions: Int    // 回滚后删除的行数（当前比备份多的行）
    let category: FileChangeCategory
}

/// 对单个文件计算 diff 统计。返回 nil 表示文件未变化或计算出错。
private func computeFileResult(
    relativePath: String,
    entry: FileBackupEntry,
    checkpoint: ConversationCheckpoint,
    diffEngine: StructuredDiffEngine
) async -> RewindFileResult? {
    let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)
    let fm = FileManager.default

    if let backupKey = entry.backupKey {
        // 文件在快照时存在
        let backupContent = await fileBackupStore.readBackupContent(
            backupKey: backupKey,
            sessionID: checkpoint.sessionID
        )

        let currentExists = fm.fileExists(atPath: absPath)
        let currentContent: String? = currentExists
            ? (try? String(contentsOfFile: absPath, encoding: .utf8))
            : nil

        if !currentExists {
            // 文件被 agent 删除 → 回滚后会被恢复 (category: .deleted)
            guard let backup = backupContent else { return nil }
            guard let diff = try? diffEngine.build(
                relativePath: relativePath,
                absolutePath: absPath,
                kind: .add,
                baseContent: nil,       // 当前无内容
                stagedContent: backup   // 备份 = 恢复目标（从 StructuredDiffEngine 视角是"新增文件"）
            ) else { return nil }
            return RewindFileResult(
                absolutePath: absPath,
                insertions: diff.summary.additions,  // 恢复后会新增的行
                deletions: diff.summary.deletions,
                category: .deleted
            )
        }

        // 文件存在，检查内容是否变化
        guard await fileBackupStore.hasFileChanged(
            filePath: absPath,
            sessionID: checkpoint.sessionID,
            entry: entry
        ) else {
            return nil  // 未变化，跳过
        }

        // 内容已变化 → 计算 diff（baseContent = 备份，stagedContent = 当前）
        guard let diff = try? diffEngine.build(
            relativePath: relativePath,
            absolutePath: absPath,
            kind: .modify,
            baseContent: backupContent,   // 备份（旧）
            stagedContent: currentContent // 当前（新）
        ) else { return nil }

        // insertions = 备份比当前多的行（回滚后会出现）= diff.summary.deletions（从 base→staged 视角）
        // deletions  = 当前比备份多的行（回滚后会消失）= diff.summary.additions
        return RewindFileResult(
            absolutePath: absPath,
            insertions: diff.summary.deletions,
            deletions: diff.summary.additions,
            category: .modified
        )

    } else {
        // backupKey == nil：文件在快照时不存在
        guard fm.fileExists(atPath: absPath) else {
            return nil  // 快照时不存在，现在也不存在 → 无变化
        }

        // 文件由 agent 新增 → 回滚后会被删除 (category: .added)
        let currentContent = try? String(contentsOfFile: absPath, encoding: .utf8)
        guard let diff = try? diffEngine.build(
            relativePath: relativePath,
            absolutePath: absPath,
            kind: .delete,
            baseContent: currentContent,  // 当前（将被删除）
            stagedContent: nil            // 快照时不存在
        ) else { return nil }

        // 从恢复视角：回滚后会删除所有当前行 → insertions = 0，deletions = 当前行数
        return RewindFileResult(
            absolutePath: absPath,
            insertions: 0,
            deletions: diff.summary.deletions,
            category: .added
        )
    }
}
```

（以上两段代码写在 `actor RewindPreflightInspector { ... }` 的大括号内部，紧接在 `computeDiffStats` 方法之后。）

### Step 5: 运行全部测试，确认通过

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc3-derived \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Suite.*passed|Suite.*failed|Test.*passed|Test.*failed"
```

预期：10 个测试全部 passed。

### Step 6: Commit

```bash
git add agentGui/Services/Rewind/RewindPreflightInspector.swift \
        agentGui/Services/Rewind/FileBackupStore.swift \
        agentGuiTests/RewindPreflightInspectorTests.swift
git commit -m "feat(rewind): R-C3 computeDiffStats — per-file parallel diff with StructuredDiffEngine"
```

---

## Task 4：注册到 Xcode 项目（如缺失）

**Files:**
- Modify: `agentGui.xcodeproj/project.pbxproj`（通过 Xcode UI，非手动编辑）

### Step 1: 检查文件是否已在 Xcode Target

```bash
grep "RewindPreflightInspector" /Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj
```

若无输出，说明新文件未加入 Target，需要在 Xcode 中：
1. 打开 `agentGui.xcodeproj`
2. 右键 `agentGui/Services/Rewind/` 组
3. 选 "Add Files to agentGui..."，选中 `RewindPreflightInspector.swift`，勾选 `agentGui` Target

### Step 2: Build 确认无编译错误

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期输出：`BUILD SUCCEEDED`

### Step 3: 运行完整 smoke test（确认没有破坏其他测试）

```bash
cd /Volumes/T7/文稿/Projects/agentGui && xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc3-smoke-derived \
  -only-testing:agentGuiTests/RewindPreflightInspectorTests \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  -only-testing:agentGuiTests/FileSystemRewindCoordinatorTests \
  -only-testing:agentGuiTests/ConversationCheckpointModelTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Suite.*passed|Suite.*failed"
```

预期：所有 Suite passed。

### Step 4: Commit

```bash
git add agentGui.xcodeproj/project.pbxproj
git commit -m "chore(rewind): register RewindPreflightInspector.swift in Xcode target"
```

---

## 验收清单

| 验收标准 | 对应测试 |
|---------|---------|
| 无追踪文件 → `hasAnyFileChanges = false` | `hasAnyFileChanges_emptyCheckpoint_returnsFalse` |
| 文件未变化 → `hasAnyFileChanges = false` | `hasAnyFileChanges_fileUnchanged_returnsFalse` |
| 文件已修改 → `hasAnyFileChanges = true` | `hasAnyFileChanges_fileModified_returnsTrue` |
| nil backup + 文件现存在 → `true` | `hasAnyFileChanges_nilBackupFileNowExists_returnsTrue` |
| 多文件早退 → 正确返回 true | `hasAnyFileChanges_earlyExitOnFirstChanged` |
| 空检查点 → `computeDiffStats = .empty` | `computeDiffStats_emptyCheckpoint_returnsEmpty` |
| 修改文件 → `modifiedFiles` + insertions/deletions > 0 | `computeDiffStats_modifiedFile_correctStats` |
| agent 新增文件 → `addedFiles` 包含该路径 | `computeDiffStats_newFileCreatedByAgent_inAddedFiles` |
| agent 删除文件 → `deletedFiles` 包含该路径 | `computeDiffStats_fileDeletedByAgent_inDeletedFiles` |
| 未变化文件 → `filesChanged` 为空 | `computeDiffStats_unchangedFile_notInFilesChanged` |

---

## 与其他 Feature 的接口

R-C3 完成后，R-D1/D2 将通过以下方式使用它：

```swift
// R-D1: MessageRewindSelectorView — 判断是否需要显示确认对话框
let inspector = RewindPreflightInspector(fileBackupStore: fileBackupStore)
let needsConfirmation = try await inspector.hasAnyFileChanges(checkpoint: checkpoint)
if needsConfirmation {
    // 打开 R-D2 RewindConfirmationSheet
} else {
    // lossless fast path：直接执行回滚
    try await rewindTransactionCoordinator.execute(...)
}

// R-D2: RewindConfirmationSheet — 填充 diff 预览区
let stats = try await inspector.computeDiffStats(checkpoint: checkpoint)
// 展示 stats.filesChanged.count、stats.totalInsertions、stats.totalDeletions 等
```
