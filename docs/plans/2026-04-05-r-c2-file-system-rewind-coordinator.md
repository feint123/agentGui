# R-C2 FileSystemRewindCoordinator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `FileSystemRewindCoordinator`（R-C2），负责将工作区文件系统恢复到指定 `ConversationCheckpoint` 所记录的状态，是 Rewind 功能文件层的最后一个 P0 服务。

**Architecture:** `@MainActor final class`，接收已有的 `FileBackupStore`（actor），通过解码 `ConversationCheckpoint.trackedFileBackupsJSON` 获取文件备份映射，逐文件调用 `hasFileChanged` + `restoreFile`，以容错方式（non-atomic，每文件独立错误）完成恢复，最后 post `rewindDidRestoreFiles` 通知触发 Editor 刷新。

**Tech Stack:** Swift 6, `@MainActor`, SwiftData（只读访问 `ConversationCheckpoint`），`FileBackupStore` actor，`NotificationCenter`，Swift Testing (`@Suite` / `@Test` / `#expect`)。

---

## 依赖状态核查

在开始前，确认以下组件已实现（只读，不修改）：

| 文件 | 组件 | 状态 |
|------|------|------|
| `agentGui/Models/ConversationCheckpoint.swift` | `ConversationCheckpoint`, `FileBackupEntry` | ✅ 已存在 |
| `agentGui/Services/Rewind/FileBackupStore.swift` | `FileBackupStore` actor | ✅ 已存在 |
| `agentGui/Services/Rewind/ConversationRewindCoordinator.swift` | R-C1, `Notification.Name.rewindDidPruneConversation` | ✅ 已存在 |

---

## 关键设计决策

### 为什么是 `@MainActor final class` 而非 `actor`？

`ConversationCheckpoint` 是 SwiftData `@Model`，在 Swift 6 strict concurrency 下不是 `Sendable`，无法跨 actor 边界传递。选择 `@MainActor final class` 与 R-C1 `ConversationRewindCoordinator` 保持一致；所有文件 I/O 通过 `await fileBackupStore.*`（`FileBackupStore` 自身是 actor，内部 IO 已序列化）完成，不阻塞主线程。

### 路径解析规则

`ConversationCheckpoint.trackedFileBackupsJSON` 的 key 由 `FileCheckpointHook.preExecute` 写入，规则为：
- 若目标文件绝对路径以 `workspaceRoot + "/"` 开头 → key = 相对路径（如 `"src/main.swift"`）
- 否则 → key = 绝对路径（如 `/opt/external/config.sh`）

恢复时绝对路径解析：

```swift
func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
    relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
}
```

### RewindResult 语义

- `restoredFiles`：实际写入磁盘的绝对路径（内容有差异并成功恢复）
- `skippedFiles`：内容与备份相同，无需操作的绝对路径
- `failedFiles`：恢复失败的绝对路径 + 错误（不影响其他文件）

### 通知发布时机

`rewindDidRestoreFiles` 在所有文件处理完成后（包括部分失败）统一发布，不因 `failedFiles` 非空而跳过。`object` = sessionID，`userInfo` 包含恢复文件列表，供 CodeEditor/ChangeReview 视图刷新。

---

## 新增文件

```text
agentGui/Services/Rewind/FileSystemRewindCoordinator.swift  ← 本 feature
agentGuiTests/FileSystemRewindCoordinatorTests.swift        ← 测试
```

不修改任何现有文件。

---

## Task 1：实现 `FileSystemRewindCoordinator` 骨架（可编译存根）

**File:**
- Create: `agentGui/Services/Rewind/FileSystemRewindCoordinator.swift`

### Step 1：写入骨架文件

写入以下内容，确保能编译通过（测试尚未存在）：

```swift
// agentGui/Services/Rewind/FileSystemRewindCoordinator.swift
import Foundation
import SwiftData

// MARK: - Notification.Name

extension Notification.Name {
    /// 文件系统恢复完成后发出。
    /// - object: sessionID (String)
    /// - userInfo: ["restoredFiles": [String]] — 实际被恢复的绝对路径列表
    static let rewindDidRestoreFiles = Notification.Name("agentGui.rewindDidRestoreFiles")
}

// MARK: - FileSystemRewindCoordinator

/// R-C2: 将工作区文件系统恢复到指定 ConversationCheckpoint 所记录的状态。
///
/// ## 职责边界
/// - 只负责文件系统恢复，不截断对话（R-C1）
/// - 不负责取消 agent loop（R-C4 先完成）
/// - 恢复为 non-atomic：每文件独立容错，单文件失败不影响其他文件
///
/// ## 并发安全
/// `@MainActor`：SwiftData `@Model` 只在 MainActor 访问；
/// 文件 IO 通过 `await fileBackupStore.*` 委托给 `FileBackupStore` actor。
@MainActor
final class FileSystemRewindCoordinator {

    // MARK: - Types

    struct RewindResult {
        /// 实际被恢复的文件绝对路径列表（内容有差异并成功恢复）。
        var restoredFiles: [String]
        /// 与备份内容相同、无需恢复的文件绝对路径列表。
        var skippedFiles: [String]
        /// 恢复失败的文件绝对路径及对应错误。
        var failedFiles: [(path: String, error: Error)]
    }

    // MARK: - Dependencies

    private let fileBackupStore: FileBackupStore

    // MARK: - Init

    init(fileBackupStore: FileBackupStore) {
        self.fileBackupStore = fileBackupStore
    }

    // MARK: - Public API

    /// 将文件系统恢复到 `checkpoint` 记录的状态。
    ///
    /// - Parameter checkpoint: 目标检查点，由 `ConversationCheckpointService` 创建。
    /// - Returns: 包含已恢复、已跳过、已失败文件列表的结构体。
    /// - Throws: `ConversationCheckpointError` 若 JSON 解码失败（极少，备份元数据损坏）。
    func rewind(to checkpoint: ConversationCheckpoint) async throws -> RewindResult {
        fatalError("Not implemented")
    }
}

// MARK: - Private Helpers

private extension FileSystemRewindCoordinator {

    /// 将 relativePath（字典 key）解析为绝对路径。
    /// relativePath 以 "/" 开头时视为绝对路径（文件在 workspaceRoot 之外）。
    func absolutePath(for relativePath: String, workspaceRoot: String) -> String {
        relativePath.hasPrefix("/") ? relativePath : workspaceRoot + "/" + relativePath
    }
}
```

### Step 2：确认可编译

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build succeeded"
```

期望输出：`Build succeeded`（或零 `error:` 行）。

### Step 3：Commit

```bash
git add agentGui/Services/Rewind/FileSystemRewindCoordinator.swift
git commit -m "feat(rewind): add FileSystemRewindCoordinator stub (R-C2)"
```

---

## Task 2：写失败测试——核心恢复逻辑

**File:**
- Create: `agentGuiTests/FileSystemRewindCoordinatorTests.swift`

> 测试框架：Swift Testing（`import Testing`），与 `FileBackupStoreTests.swift` 和 `ConversationRewindCoordinatorTests.swift` 保持一致。

### Step 1：写测试文件

```swift
// agentGuiTests/FileSystemRewindCoordinatorTests.swift
import Foundation
import Testing
import SwiftData
@testable import agentGui

// MARK: - Shared Helpers

/// 创建内存 ModelContainer（包含 ConversationCheckpoint schema）
@MainActor
private func makeContainer() throws -> ModelContainer {
    let schema = Schema(PersistenceSchema.sharedModelTypes)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

/// 在 tmp 下创建一个 ConversationCheckpoint（含一条 FileBackupEntry）
/// relativePath / backupKey 可由调用方控制
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

// MARK: - Test Suite

@MainActor
@Suite("FileSystemRewindCoordinator Tests")
struct FileSystemRewindCoordinatorTests {

    // MARK: - Infrastructure helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Test 1: 修改后的文件被恢复为备份内容

    @Test
    func rewind_modifiedFile_restoredToBackupContent() async throws {
        // Arrange
        let sessionID = "session-restore-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        // 创建源文件（原始内容）
        let sourceFile = workspaceRoot + "/hello.txt"
        try "original content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        // 备份原始内容
        let entry = try await store.createBackup(filePath: sourceFile, sessionID: sessionID, version: 1)
        #expect(entry.backupKey != nil)

        // 修改源文件（模拟 agent 写入）
        try "modified content".write(toFile: sourceFile, atomically: true, encoding: .utf8)

        // 构造 Checkpoint
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let fullEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: 1,
            backupTime: entry.backupTime,
            originalRelativePath: "hello.txt"
        )
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: ["hello.txt": fullEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件内容已恢复
        let restoredContent = try String(contentsOfFile: sourceFile, encoding: .utf8)
        #expect(restoredContent == "original content")

        // Assert: result 分类正确
        #expect(result.restoredFiles == [sourceFile])
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 2: backupKey=nil 的文件（快照时不存在）在回滚时被删除

    @Test
    func rewind_newFileCreatedAfterSnapshot_deletedOnRewind() async throws {
        // Arrange
        let sessionID = "session-delete-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        // 备份时文件不存在 → backupKey = nil
        let relPath = "new_file.txt"
        let absoluteFilePath = workspaceRoot + "/" + relPath
        let nilEntry = FileBackupEntry(
            backupKey: nil,
            version: 1,
            backupTime: Date(),
            originalRelativePath: relPath
        )

        // Agent 之后创建了这个文件
        try "agent created this".write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: absoluteFilePath))

        // 构造 Checkpoint
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [relPath: nilEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件已被删除
        #expect(!FileManager.default.fileExists(atPath: absoluteFilePath))

        // Assert: result 分类正确
        #expect(result.restoredFiles == [absoluteFilePath])
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 3: 文件内容与备份相同时跳过（skippedFiles）

    @Test
    func rewind_unchangedFile_addedToSkippedFilesOnly() async throws {
        // Arrange
        let sessionID = "session-skip-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
        try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

        let store = FileBackupStore(baseURL: backupBaseDir)

        let relPath = "unchanged.txt"
        let absoluteFilePath = workspaceRoot + "/" + relPath
        try "same content".write(toFile: absoluteFilePath, atomically: true, encoding: .utf8)

        // 备份内容与当前文件相同
        let entry = try await store.createBackup(filePath: absoluteFilePath, sessionID: sessionID, version: 1)
        // 不修改文件（模拟文件未被 agent 改动）

        let fullEntry = FileBackupEntry(
            backupKey: entry.backupKey,
            version: 1,
            backupTime: entry.backupTime,
            originalRelativePath: relPath
        )

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: workspaceRoot,
            entries: [relPath: fullEntry],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 文件内容不变
        let content = try String(contentsOfFile: absoluteFilePath, encoding: .utf8)
        #expect(content == "same content")

        // Assert: 归类为 skipped，不在 restored
        #expect(result.skippedFiles == [absoluteFilePath])
        #expect(result.restoredFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }

    // MARK: - Test 4: 空检查点（无 tracked 文件）→ 全空结果

    @Test
    func rewind_emptyCheckpoint_returnsEmptyResult() async throws {
        let sessionID = "session-empty-\(UUID().uuidString)"
        let tmpDir = try makeTempDir()
        let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
        let store = FileBackupStore(baseURL: backupBaseDir)

        let container = try makeContainer()
        let ctx = ModelContext(container)
        let checkpoint = try makeCheckpoint(
            sessionID: sessionID,
            workspaceRoot: tmpDir.path,
            entries: [:],
            in: ctx
        )

        let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

        // Act
        let result = try await coordinator.rewind(to: checkpoint)

        // Assert: 全空
        #expect(result.restoredFiles.isEmpty)
        #expect(result.skippedFiles.isEmpty)
        #expect(result.failedFiles.isEmpty)
    }
}
```

### Step 2：确认测试编译并失败（fatalError 触发）

在添加真实实现之前，运行测试以验证 fatalError 会导致测试失败（不是 build 失败）：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc2-derived \
  -only-testing:agentGuiTests/FileSystemRewindCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

期望：测试**失败**（crash on fatalError），不是编译错误。

### Step 3：Commit

```bash
git add agentGuiTests/FileSystemRewindCoordinatorTests.swift
git commit -m "test(rewind): add failing tests for FileSystemRewindCoordinator (R-C2)"
```

---

## Task 3：实现 `rewind(to:)` 核心逻辑（让 Task 2 的测试全部通过）

**File:**
- Modify: `agentGui/Services/Rewind/FileSystemRewindCoordinator.swift`

### Step 1：替换 `fatalError` 桩，写入真实实现

将 `rewind(to:)` 方法全部替换为：

```swift
func rewind(to checkpoint: ConversationCheckpoint) async throws -> RewindResult {
    // 1. 解码 trackedFileBackupsJSON（若 JSON 损坏则 throw，这是唯一 throw 路径）
    let trackedFileBackups = try checkpoint.decodedTrackedFileBackups()

    var restoredFiles: [String] = []
    var skippedFiles: [String] = []
    var failedFiles: [(path: String, error: Error)] = []

    // 2. 逐文件处理（non-atomic：单文件失败不影响其他文件）
    for (relativePath, entry) in trackedFileBackups {
        let absPath = absolutePath(for: relativePath, workspaceRoot: checkpoint.workspaceRoot)

        do {
            let changed = await fileBackupStore.hasFileChanged(
                filePath: absPath,
                sessionID: checkpoint.sessionID,
                entry: entry
            )

            if changed {
                try await fileBackupStore.restoreFile(
                    filePath: absPath,
                    sessionID: checkpoint.sessionID,
                    from: entry
                )
                restoredFiles.append(absPath)
            } else {
                skippedFiles.append(absPath)
            }
        } catch {
            failedFiles.append((path: absPath, error: error))
        }
    }

    // 3. 发出通知，让 Editor 视图、ChangeReview 视图刷新
    NotificationCenter.default.post(
        name: .rewindDidRestoreFiles,
        object: checkpoint.sessionID,
        userInfo: ["restoredFiles": restoredFiles]
    )

    return RewindResult(
        restoredFiles: restoredFiles,
        skippedFiles: skippedFiles,
        failedFiles: failedFiles
    )
}
```

### Step 2：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc2-derived \
  -only-testing:agentGuiTests/FileSystemRewindCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

期望输出（4 个 Test 全部 passed）：

```
Test rewind_modifiedFile_restoredToBackupContent passed
Test rewind_newFileCreatedAfterSnapshot_deletedOnRewind passed
Test rewind_unchangedFile_addedToSkippedFilesOnly passed
Test rewind_emptyCheckpoint_returnsEmptyResult passed
```

### Step 3：Commit

```bash
git add agentGui/Services/Rewind/FileSystemRewindCoordinator.swift
git commit -m "feat(rewind): implement FileSystemRewindCoordinator.rewind (R-C2)"
```

---

## Task 4：补充边缘用例测试

**File:**
- Modify: `agentGuiTests/FileSystemRewindCoordinatorTests.swift`

### Step 1：写 2 个边缘用例测试，追加到 `FileSystemRewindCoordinatorTests` 末尾

**Test 5：部分文件恢复失败 → failedFiles，其他文件正常恢复**

```swift
// MARK: - Test 5: 部分文件恢复失败不影响其他文件

@Test
func rewind_partialFailure_otherFilesStillRestored() async throws {
    // Arrange
    let sessionID = "session-partial-\(UUID().uuidString)"
    let tmpDir = try makeTempDir()
    let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
    let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
    try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

    let store = FileBackupStore(baseURL: backupBaseDir)

    // 文件 A：正常修改，备份存在 → 应该被恢复
    let relPathA = "file_a.txt"
    let absPathA = workspaceRoot + "/" + relPathA
    try "original A".write(toFile: absPathA, atomically: true, encoding: .utf8)
    let entryA = try await store.createBackup(filePath: absPathA, sessionID: sessionID, version: 1)
    try "modified A".write(toFile: absPathA, atomically: true, encoding: .utf8)

    // 文件 B：backupKey 指向一个不存在的备份文件（模拟备份损坏）→ 应进入 failedFiles
    let relPathB = "file_b.txt"
    let absPathB = workspaceRoot + "/" + relPathB
    try "some content B".write(toFile: absPathB, atomically: true, encoding: .utf8)
    let brokenEntry = FileBackupEntry(
        backupKey: "nonexistent_hash.v1",   // 不存在的 backupKey
        version: 1,
        backupTime: Date(),
        originalRelativePath: relPathB
    )

    let fullEntryA = FileBackupEntry(
        backupKey: entryA.backupKey,
        version: 1,
        backupTime: entryA.backupTime,
        originalRelativePath: relPathA
    )

    let container = try makeContainer()
    let ctx = ModelContext(container)
    let checkpoint = try makeCheckpoint(
        sessionID: sessionID,
        workspaceRoot: workspaceRoot,
        entries: [relPathA: fullEntryA, relPathB: brokenEntry],
        in: ctx
    )

    let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

    // Act
    let result = try await coordinator.rewind(to: checkpoint)

    // Assert: 文件 A 已恢复
    let contentA = try String(contentsOfFile: absPathA, encoding: .utf8)
    #expect(contentA == "original A")
    #expect(result.restoredFiles.contains(absPathA))

    // Assert: 文件 B 进入 failedFiles（备份不存在）
    #expect(result.failedFiles.map(\.path).contains(absPathB))

    // Assert: 失败的文件数量为 1
    #expect(result.failedFiles.count == 1)
}
```

**Test 6：通知在 rewind 完成后发出，包含 restoredFiles userInfo**

```swift
// MARK: - Test 6: rewindDidRestoreFiles 通知在完成后发出

@Test
func rewind_postsRewindDidRestoreFilesNotification() async throws {
    // Arrange
    let sessionID = "session-notif-\(UUID().uuidString)"
    let tmpDir = try makeTempDir()
    let backupBaseDir = tmpDir.appendingPathComponent("checkpoints")
    let workspaceRoot = tmpDir.appendingPathComponent("workspace").path
    try FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)

    let store = FileBackupStore(baseURL: backupBaseDir)

    let relPath = "notify_me.txt"
    let absPath = workspaceRoot + "/" + relPath
    try "before".write(toFile: absPath, atomically: true, encoding: .utf8)
    let entry = try await store.createBackup(filePath: absPath, sessionID: sessionID, version: 1)
    try "after".write(toFile: absPath, atomically: true, encoding: .utf8)

    let fullEntry = FileBackupEntry(
        backupKey: entry.backupKey,
        version: 1,
        backupTime: entry.backupTime,
        originalRelativePath: relPath
    )

    let container = try makeContainer()
    let ctx = ModelContext(container)
    let checkpoint = try makeCheckpoint(
        sessionID: sessionID,
        workspaceRoot: workspaceRoot,
        entries: [relPath: fullEntry],
        in: ctx
    )

    let coordinator = FileSystemRewindCoordinator(fileBackupStore: store)

    // 监听通知
    var receivedSessionID: String?
    var receivedRestoredFiles: [String]?
    let observer = NotificationCenter.default.addObserver(
        forName: .rewindDidRestoreFiles,
        object: nil,
        queue: .main
    ) { notification in
        receivedSessionID = notification.object as? String
        receivedRestoredFiles = notification.userInfo?["restoredFiles"] as? [String]
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // Act
    _ = try await coordinator.rewind(to: checkpoint)

    // Assert: 通知已发出，sessionID 和 restoredFiles 正确
    #expect(receivedSessionID == sessionID)
    let restoredInNotif = try #require(receivedRestoredFiles)
    #expect(restoredInNotif.contains(absPath))
}
```

### Step 2：运行全部 6 个测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc2-derived \
  -only-testing:agentGuiTests/FileSystemRewindCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

期望：6 个 passed，0 个 failed。

### Step 3：Commit

```bash
git add agentGuiTests/FileSystemRewindCoordinatorTests.swift
git commit -m "test(rewind): add edge case tests for FileSystemRewindCoordinator (R-C2)"
```

---

## Task 5：集成冒烟测试（与 R-C1 一起跑）

### Step 1：运行 Rewind Coordinator 全套测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rc2-final-derived \
  -only-testing:agentGuiTests/FileSystemRewindCoordinatorTests \
  -only-testing:agentGuiTests/ConversationRewindCoordinatorTests \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

期望：所有测试 passed，无 error。

### Step 2：确认全量 Build 仍然成功

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:.*error|Build succeeded"
```

期望：`Build succeeded`。

### Step 3：最终 Commit

```bash
git add -A
git commit -m "feat(rewind): complete R-C2 FileSystemRewindCoordinator — all tests passing"
```

---

## 验收标准对照表

| 设计文档验收标准 | 对应测试 | 状态 |
|------|------|------|
| agent 写入的文件在回滚后内容恢复为修改前状态 | Test 1: `rewind_modifiedFile_restoredToBackupContent` | Task 2 |
| 新增的文件（entry.backupKey == nil）在回滚后被删除 | Test 2: `rewind_newFileCreatedAfterSnapshot_deletedOnRewind` | Task 2 |
| 内容与备份相同的文件放入 skippedFiles | Test 3: `rewind_unchangedFile_addedToSkippedFilesOnly` | Task 2 |
| 空检查点返回全空结果 | Test 4: `rewind_emptyCheckpoint_returnsEmptyResult` | Task 2 |
| 部分文件恢复失败时不影响其他文件恢复（非原子，逐文件容错） | Test 5: `rewind_partialFailure_otherFilesStillRestored` | Task 4 |
| 发出 `RewindDidRestoreFiles` 通知 | Test 6: `rewind_postsRewindDidRestoreFilesNotification` | Task 4 |

---

## 后续依赖

R-C2 完成后，以下工作解锁：

- **R-C3 `RewindPreflightInspector`**（P1）：`hasAnyFileChanges` 和 `computeDiffStats` 复用 `FileBackupStore.hasFileChanged`，与 R-C2 并列但不依赖。
- **R-C4 `RewindTransactionCoordinator`**（P0）：依赖 R-C2 的 `FileSystemRewindCoordinator.rewind` 和 R-C1 的 `ConversationRewindCoordinator.rewindTo`。
- **R-D1/D2 UI 层**（P1）：需要 R-C4 完成后方可接入。
