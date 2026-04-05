# R-B2 CheckpointGCService 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `CheckpointGCService`，防止 Rewind 备份文件无限增长——对每个 session 执行检查点 eviction（最多保留 50 条）、清理孤立备份文件，并在 session 被删除时立即清理对应的全部检查点和备份目录。

**Architecture:** 纯 `actor`，无 UI 依赖；三种 GC 入口相互独立：`evictOldCheckpoints`（SwiftData 层面按 session 保留最近 N 条）、`pruneOrphanBackupFiles`（磁盘扫描，比对存活 backupKey 集合删除孤立文件）、`purgeSession`（session 删除时全量清理）。`SessionDeletionCoordinator` 调用 `purgeSession`，app 启动时触发全量 GC。

**Tech Stack:** Swift 6 actor, SwiftData `ModelContext`（@MainActor），Foundation `FileManager`，现有 `FileBackupStore`（`deleteBackups(forSession:)`），`ConversationCheckpoint`（`agentGui/Models/ConversationCheckpoint.swift`），`SessionDeletionCoordinator`（`agentGui/Services/Channels/SessionDeletionCoordinator.swift`）

---

## 背景速查

### R-B2 在设计文档中的定义

见 `docs/plans/2026-04-04-rewind-feature-design.md` § Layer R-B — R-B2：

> **检查点 eviction：** 每个 session 保留最近 `maxCheckpoints`（默认 50）个 `ConversationCheckpoint`，超出时删除最旧的记录。  
> **备份文件 GC：** 扫描磁盘上的备份文件，比对仍存活的 `ConversationCheckpoint` 中引用的 `backupKey` 集合，删除无引用的孤立文件。  
> **Session 清理：** 当 `Session` 被删除时，触发对应 session 的全量 checkpoint 和备份清理。

### 参考：Claude Code 对应实现

Claude Code 的 eviction 逻辑位于
`/Users/feint/Downloads/claude-code-source-code-main/src/utils/fileHistory.ts`，`fileHistoryMakeSnapshot` 内的 commit 阶段：

```typescript
const allSnapshots = [...state.snapshots, newSnapshot]
const updatedState: FileHistoryState = {
  snapshots:
    allSnapshots.length > MAX_SNAPSHOTS
      ? allSnapshots.slice(-MAX_SNAPSHOTS)  // FIFO eviction
      : allSnapshots,
  snapshotSequence: (state.snapshotSequence ?? 0) + 1,
}
```

**注意：** Claude Code 仅 evict 内存中的快照引用，备份**文件**不删除（依赖 resume 机制跨会话保留）。agentGui 的 GC 需要主动删除磁盘上的孤立备份文件，因为我们没有 resume 依赖——这是 agentGui 对 Claude Code 的增强点。

### agentGui 现有基础

| 元素 | 文件 | 说明 |
|------|------|------|
| `ConversationCheckpoint` | `agentGui/Models/ConversationCheckpoint.swift` | SwiftData @Model，`snapshotSequence`、`sessionID`、`trackedFileBackupsJSON` |
| `FileBackupEntry.backupKey` | 同上 | 内容哈希键，`nil` = 文件快照时不存在 |
| `FileBackupStore.deleteBackups(forSession:)` | `agentGui/Services/Rewind/FileBackupStore.swift` | 删除指定 session 目录下所有备份文件 |
| `SessionDeletionCoordinator` | `agentGui/Services/Channels/SessionDeletionCoordinator.swift` | session 删除入口，需在此注入 purge 调用 |
| 备份根目录 | `ConfigDirectoryManager.shared.agentGuiDir/checkpoints/{sessionID}/` | session 级磁盘分目录 |

### 备份路径结构（R-A2 约定）

```
~/.agentgui/checkpoints/
  {sessionID}/
    {backupKey[:2]}/
      {backupKey}.bak
```

`backupKey` = `"{sha256}.v{version}"`（不含 `.bak`）

---

## Task 1：新建 `CheckpointGCService.swift` 骨架 + eviction 逻辑

**Files:**
- Create: `agentGui/Services/Rewind/CheckpointGCService.swift`
- Create: `agentGuiTests/CheckpointGCServiceTests.swift`

### Step 1：写失败测试——eviction 只保留最新 N 条

```swift
// agentGuiTests/CheckpointGCServiceTests.swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct CheckpointGCServiceTests {

    // MARK: - Helpers

    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([ConversationCheckpoint.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func insertCheckpoint(
        sessionID: String,
        sequence: Int,
        context: ModelContext
    ) throws -> ConversationCheckpoint {
        let cp = try ConversationCheckpoint(
            sessionID: sessionID,
            messageID: UUID(),
            snapshotSequence: sequence,
            workspaceRoot: "/tmp/ws",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        context.insert(cp)
        return cp
    }

    // MARK: - evictOldCheckpoints

    @Test
    func eviction_keepsLatestNCheckpoints_deletesOlderOnes() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s1", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s1", modelContext: context, maxCheckpoints: 5)

        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s1" },
                sortBy: [SortDescriptor(\.snapshotSequence)]
            )
        )
        // 保留最新 5 条（sequence 5..9），删除旧 5 条（sequence 0..4）
        #expect(remaining.count == 5)
        #expect(remaining.first?.snapshotSequence == 5)
        #expect(remaining.last?.snapshotSequence == 9)
    }

    @Test
    func eviction_doesNothing_whenBelowLimit() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<3 {
            _ = try insertCheckpoint(sessionID: "s2", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s2", modelContext: context, maxCheckpoints: 50)

        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s2" }
            )
        )
        #expect(remaining.count == 3)
    }

    @Test
    func eviction_isolatedPerSession_doesNotTouchOtherSessions() async throws {
        let container = try makeTestContainer()
        let context = container.mainContext
        let svc = CheckpointGCService()

        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s3", sequence: seq, context: context)
        }
        for seq in 0..<10 {
            _ = try insertCheckpoint(sessionID: "s4", sequence: seq, context: context)
        }
        try context.save()

        await svc.evictOldCheckpoints(sessionID: "s3", modelContext: context, maxCheckpoints: 3)

        let s3Remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s3" }
            )
        )
        let s4Remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "s4" }
            )
        )
        #expect(s3Remaining.count == 3)
        #expect(s4Remaining.count == 10)  // s4 未受影响
    }
}
```

**Step 2：运行测试，确认全部失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:|warning:" | head -30
```

预期：`CheckpointGCService` 类型不存在，编译失败。

**Step 3：新建骨架 + 实现 `evictOldCheckpoints`**

```swift
// agentGui/Services/Rewind/CheckpointGCService.swift
import Foundation
import SwiftData

/// R-B2: 检查点 GC 服务。
///
/// 三种独立 GC 入口：
/// - `evictOldCheckpoints`  — 按 session 保留最近 N 个检查点，删除旧记录（SwiftData 层）
/// - `pruneOrphanBackupFiles` — 扫描磁盘备份文件，比对存活 backupKey 集合，删除孤立文件
/// - `purgeSession`          — session 删除时全量清理（SwiftData + 磁盘）
actor CheckpointGCService: Sendable {

    // MARK: - Configuration

    let defaultMaxCheckpoints: Int

    private let fileBackupStore: FileBackupStore
    private let checkpointsBaseURL: URL

    // MARK: - Init

    init(
        fileBackupStore: FileBackupStore? = nil,
        defaultMaxCheckpoints: Int = 50,
        checkpointsBaseURL: URL? = nil
    ) {
        self.fileBackupStore = fileBackupStore ?? FileBackupStore()
        self.defaultMaxCheckpoints = defaultMaxCheckpoints
        self.checkpointsBaseURL = checkpointsBaseURL
            ?? ConfigDirectoryManager.shared.agentGuiDir
                .appendingPathComponent("checkpoints", isDirectory: true)
    }

    // MARK: - Eviction

    /// 保留指定 session 最新的 `maxCheckpoints` 条检查点，删除旧记录（FIFO）。
    /// SwiftData 操作在 @MainActor.run 内执行。
    /// 注意：此方法仅删除 SwiftData 记录；备份文件的孤立清理由 `pruneOrphanBackupFiles` 负责。
    func evictOldCheckpoints(
        sessionID: String,
        modelContext: ModelContext,
        maxCheckpoints: Int? = nil
    ) async {
        let limit = maxCheckpoints ?? defaultMaxCheckpoints
        await MainActor.run {
            do {
                // 按 snapshotSequence 升序获取所有检查点（最旧在前）
                var descriptor = FetchDescriptor<ConversationCheckpoint>(
                    predicate: #Predicate { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.snapshotSequence, order: .forward)]
                )
                let all = try modelContext.fetch(descriptor)
                guard all.count > limit else { return }

                let toDelete = all.dropLast(limit)
                for cp in toDelete {
                    modelContext.delete(cp)
                }
                try modelContext.save()
            } catch {
                // GC 失败不应影响主流程，仅静默记录
                print("[CheckpointGCService] evictOldCheckpoints failed: \(error)")
            }
        }
    }
}
```

**Step 4：运行测试，确认 eviction 相关测试通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/eviction_keepsLatestNCheckpoints_deletesOlderOnes \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/eviction_doesNothing_whenBelowLimit \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/eviction_isolatedPerSession_doesNotTouchOtherSessions \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | head -20
```

预期：3 个测试全部 passed。

**Step 5：提交**

```bash
git add agentGui/Services/Rewind/CheckpointGCService.swift \
        agentGuiTests/CheckpointGCServiceTests.swift
git commit -m "feat(R-B2): add CheckpointGCService skeleton + evictOldCheckpoints"
```

---

## Task 2：实现 `pruneOrphanBackupFiles`

孤立文件 = 磁盘上存在但没有任何存活 `ConversationCheckpoint` 引用其 `backupKey` 的 `.bak` 文件。

**Files:**
- Modify: `agentGui/Services/Rewind/CheckpointGCService.swift`
- Modify: `agentGuiTests/CheckpointGCServiceTests.swift`

### Step 1：写失败测试

在 `CheckpointGCServiceTests` 中追加：

```swift
    // MARK: - pruneOrphanBackupFiles

    @Test
    func pruneOrphans_deletesUnreferencedBackupFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 创建备份文件：一个有引用，一个孤立
        let referencedKey = "aabbcc.v1"
        let orphanKey     = "deadbeef.v1"

        func createBakFile(key: String) throws -> URL {
            let shard = String(key.prefix(2))
            let dir = tmpDir
                .appendingPathComponent("s1")
                .appendingPathComponent(shard)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(key).bak")
            try "content".write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let referencedURL = try createBakFile(key: referencedKey)
        let orphanURL     = try createBakFile(key: orphanKey)

        // 只在 SwiftData 中引用 referencedKey
        let container = try makeTestContainer()
        let context = container.mainContext
        let cp = try ConversationCheckpoint(
            sessionID: "s1",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [
                "file.swift": FileBackupEntry(
                    backupKey: referencedKey,
                    version: 1,
                    backupTime: Date(),
                    originalRelativePath: "file.swift"
                )
            ],
            hasFileChanges: true
        )
        context.insert(cp)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.pruneOrphanBackupFiles(sessionID: "s1", modelContext: context)

        // 有引用的文件不删
        #expect(FileManager.default.fileExists(atPath: referencedURL.path))
        // 孤立文件被删
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }

    @Test
    func pruneOrphans_doesNothing_whenAllFilesReferenced() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let key = "112233.v1"
        let shard = String(key.prefix(2))
        let dir = tmpDir.appendingPathComponent("s5").appendingPathComponent(shard)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bakURL = dir.appendingPathComponent("\(key).bak")
        try "x".write(to: bakURL, atomically: true, encoding: .utf8)

        let container = try makeTestContainer()
        let context = container.mainContext
        let cp = try ConversationCheckpoint(
            sessionID: "s5",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [
                "a.swift": FileBackupEntry(
                    backupKey: key, version: 1, backupTime: Date(), originalRelativePath: "a.swift"
                )
            ],
            hasFileChanges: true
        )
        context.insert(cp)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.pruneOrphanBackupFiles(sessionID: "s5", modelContext: context)

        #expect(FileManager.default.fileExists(atPath: bakURL.path))
    }
```

**Step 2：运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/pruneOrphans_deletesUnreferencedBackupFiles \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/pruneOrphans_doesNothing_whenAllFilesReferenced \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

预期：2 个测试失败（方法未实现）。

**Step 3：在 `CheckpointGCService` 中追加 `pruneOrphanBackupFiles`**

```swift
    // MARK: - Orphan Backup GC

    /// 扫描指定 session 的磁盘备份目录，删除没有任何存活 ConversationCheckpoint 引用的孤立文件。
    /// 算法：
    ///   1. 从 SwiftData 读取该 session 所有存活检查点，解码所有 backupKey 构成存活集合
    ///   2. 枚举磁盘目录中的 .bak 文件
    ///   3. 删除其 backupKey 不在存活集合中的文件
    func pruneOrphanBackupFiles(
        sessionID: String,
        modelContext: ModelContext
    ) async {
        // 1. 构建存活 backupKey 集合
        let liveKeys = await collectLiveBackupKeys(sessionID: sessionID, modelContext: modelContext)

        // 2. 枚举磁盘上的 .bak 文件
        let sessionDir = checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "bak" else { continue }
            // backupKey = 文件名去掉 .bak 后缀
            let backupKey = fileURL.deletingPathExtension().lastPathComponent
            if liveKeys.contains(backupKey) { continue }
            do {
                try fm.removeItem(at: fileURL)
            } catch {
                print("[CheckpointGCService] Failed to remove orphan backup \(fileURL.lastPathComponent): \(error)")
            }
        }

        // 清理空 shard 目录（可选，不阻塞主逻辑）
        cleanEmptyShardDirs(in: sessionDir)
    }

    // MARK: - Private Helpers

    /// 从 SwiftData 取出该 session 所有检查点，解码 JSON 并收集所有非 nil backupKey。
    private func collectLiveBackupKeys(
        sessionID: String,
        modelContext: ModelContext
    ) async -> Set<String> {
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID }
            )
            guard let checkpoints = try? modelContext.fetch(descriptor) else { return Set() }
            var keys = Set<String>()
            for cp in checkpoints {
                guard let backups = try? cp.decodedTrackedFileBackups() else { continue }
                for entry in backups.values {
                    if let key = entry.backupKey {
                        keys.insert(key)
                    }
                }
            }
            return keys
        }
    }

    /// 删除 shardDir 内的空目录，防止残留空文件夹。
    private func cleanEmptyShardDirs(in sessionDir: URL) {
        let fm = FileManager.default
        guard let shardDirs = try? fm.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for dir in shardDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }
```

**Step 4：运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/pruneOrphans_deletesUnreferencedBackupFiles \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/pruneOrphans_doesNothing_whenAllFilesReferenced \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

预期：2 个测试全部 passed。

**Step 5：提交**

```bash
git add agentGui/Services/Rewind/CheckpointGCService.swift \
        agentGuiTests/CheckpointGCServiceTests.swift
git commit -m "feat(R-B2): add pruneOrphanBackupFiles to CheckpointGCService"
```

---

## Task 3：实现 `purgeSession` + `pruneAllSessions`

**Files:**
- Modify: `agentGui/Services/Rewind/CheckpointGCService.swift`
- Modify: `agentGuiTests/CheckpointGCServiceTests.swift`

### Step 1：写失败测试

```swift
    // MARK: - purgeSession

    @Test
    func purgeSession_deletesAllCheckpointsAndBackupDirForSession() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 创建 session 备份目录和文件
        let sessionDir = tmpDir.appendingPathComponent("sess-purge", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let bakFile = sessionDir.appendingPathComponent("dummy.bak")
        try "data".write(to: bakFile, atomically: true, encoding: .utf8)

        // 写入 SwiftData
        let container = try makeTestContainer()
        let context = container.mainContext
        for seq in 0..<5 {
            _ = try insertCheckpoint(sessionID: "sess-purge", sequence: seq, context: context)
        }
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.purgeSession(sessionID: "sess-purge", modelContext: context)

        // SwiftData 中的检查点全部删除
        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "sess-purge" }
            )
        )
        #expect(remaining.isEmpty)

        // 磁盘上的 session 目录被删除
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }

    @Test
    func purgeSession_doesNotTouchOtherSessions() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // session A 和 B 各有一个备份文件
        for sid in ["sess-a", "sess-b"] {
            let dir = tmpDir.appendingPathComponent(sid, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "x".write(to: dir.appendingPathComponent("x.bak"), atomically: true, encoding: .utf8)
        }

        let container = try makeTestContainer()
        let context = container.mainContext
        _ = try insertCheckpoint(sessionID: "sess-a", sequence: 0, context: context)
        _ = try insertCheckpoint(sessionID: "sess-b", sequence: 0, context: context)
        try context.save()

        let svc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        await svc.purgeSession(sessionID: "sess-a", modelContext: context)

        // sess-a 删除，sess-b 保留
        #expect(!FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("sess-a").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: tmpDir.appendingPathComponent("sess-b").path
        ))
        let bRemaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == "sess-b" }
            )
        )
        #expect(bRemaining.count == 1)
    }
```

**Step 2：运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/purgeSession_deletesAllCheckpointsAndBackupDirForSession \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/purgeSession_doesNotTouchOtherSessions \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

预期：2 个测试失败。

**Step 3：在 `CheckpointGCService` 中追加 `purgeSession` 和 `pruneAllSessions`**

```swift
    // MARK: - Session Purge

    /// session 被删除时调用：删除该 session 的所有 ConversationCheckpoint（SwiftData）
    /// 并清空磁盘上的备份目录。
    /// - Parameters:
    ///   - sessionID: 要清理的 session ID（对应 Session.sessionId）
    ///   - modelContext: 在 @MainActor 上刷新
    func purgeSession(sessionID: String, modelContext: ModelContext) async {
        // 1. 删除 SwiftData 中的检查点
        await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sessionID }
            )
            guard let checkpoints = try? modelContext.fetch(descriptor) else { return }
            for cp in checkpoints {
                modelContext.delete(cp)
            }
            try? modelContext.save()
        }

        // 2. 删除磁盘上的 session 备份目录（FileBackupStore.deleteBackups 的等价操作）
        let sessionDir = checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDir)
    }

    /// 对所有在 SwiftData 中有检查点记录的 session 执行 eviction，并全局 prune 孤立备份。
    /// 建议在 app 启动后台异步调用，不阻塞启动路径。
    func pruneAllSessions(modelContext: ModelContext, maxCheckpointsPerSession: Int? = nil) async {
        let limit = maxCheckpointsPerSession ?? defaultMaxCheckpoints

        // 1. 收集所有有检查点的 sessionID
        let sessionIDs: [String] = await MainActor.run {
            let descriptor = FetchDescriptor<ConversationCheckpoint>()
            guard let all = try? modelContext.fetch(descriptor) else { return [] }
            return Array(Set(all.map(\.sessionID)))
        }

        // 2. 逐 session evict（SwiftData 层）
        for sid in sessionIDs {
            await evictOldCheckpoints(sessionID: sid, modelContext: modelContext, maxCheckpoints: limit)
        }

        // 3. 逐 session prune 孤立磁盘文件
        for sid in sessionIDs {
            await pruneOrphanBackupFiles(sessionID: sid, modelContext: modelContext)
        }

        // 4. 清理磁盘上存在但 SwiftData 中已无检查点的孤立 session 目录
        await purgeOrphanSessionDirs(liveSessionIDs: Set(sessionIDs))
    }

    // MARK: - Private: Orphan Session Dir Cleanup

    /// 删除 checkpointsBaseURL/{sessionID} 目录中不在 liveSessionIDs 集合内的条目。
    private func purgeOrphanSessionDirs(liveSessionIDs: Set<String>) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: checkpointsBaseURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let sid = entry.lastPathComponent
            if !liveSessionIDs.contains(sid) {
                try? fm.removeItem(at: entry)
            }
        }
    }
```

**Step 4：运行 Task 3 测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/purgeSession_deletesAllCheckpointsAndBackupDirForSession \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/purgeSession_doesNotTouchOtherSessions \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

**Step 5：提交**

```bash
git add agentGui/Services/Rewind/CheckpointGCService.swift \
        agentGuiTests/CheckpointGCServiceTests.swift
git commit -m "feat(R-B2): add purgeSession + pruneAllSessions to CheckpointGCService"
```

---

## Task 4：接入 `SessionDeletionCoordinator`

session 被删除时立即调用 `CheckpointGCService.purgeSession`，清理其检查点和备份文件。

**Files:**
- Modify: `agentGui/Services/Channels/SessionDeletionCoordinator.swift`
- Modify: `agentGuiTests/CheckpointGCServiceTests.swift`（集成测试）

### Step 1：写集成测试

```swift
    // MARK: - SessionDeletionCoordinator 集成

    @Test
    func sessionDeletion_triggersCheckpointPurge() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 建立带 sessionID 的 Session 模型
        let schema = Schema([
            ConversationCheckpoint.self,
            Session.self,
            Message.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = container.mainContext

        let session = Session(workingDirectory: "/tmp")
        let sid = session.sessionId
        context.insert(session)

        // 插入检查点
        let cp = try ConversationCheckpoint(
            sessionID: sid,
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        context.insert(cp)

        // 建立磁盘备份目录
        let sessionDir = tmpDir.appendingPathComponent(sid, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "bak".write(to: sessionDir.appendingPathComponent("x.bak"), atomically: true, encoding: .utf8)

        try context.save()

        // 执行删除（通过注入 gc）
        let gc = CheckpointGCService(checkpointsBaseURL: tmpDir)
        let coordinator = SessionDeletionCoordinator(checkpointGCService: gc)
        try coordinator.delete(session, modelContext: context)

        // 检查点应被删除
        let remaining = try context.fetch(
            FetchDescriptor<ConversationCheckpoint>(
                predicate: #Predicate { $0.sessionID == sid }
            )
        )
        #expect(remaining.isEmpty)

        // 备份目录应被删除
        #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    }
```

**Step 2：运行测试，确认失败**（`SessionDeletionCoordinator` 初始化参数不匹配）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/sessionDeletion_triggersCheckpointPurge \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

**Step 3：修改 `SessionDeletionCoordinator`**

`SessionDeletionCoordinator` 当前是 `struct`，无 init 参数。在不破坏现有调用方的前提下，添加可选注入：

```swift
// agentGui/Services/Channels/SessionDeletionCoordinator.swift

@MainActor
struct SessionDeletionCoordinator {
    // 新增：可选的 GC 服务注入，nil 时不执行 checkpoint purge（向后兼容）
    private let checkpointGCService: CheckpointGCService?

    init(checkpointGCService: CheckpointGCService? = nil) {
        self.checkpointGCService = checkpointGCService
    }

    func delete(_ session: Session, modelContext: ModelContext) throws {
        guard SessionInteractionPolicy(session: session).canDelete else {
            throw SessionDeletionCoordinatorError.readOnlySession(session.sessionId)
        }
        let sessionID = session.sessionId
        pruneChannelResources(for: session, modelContext: modelContext)
        modelContext.delete(session)
        try modelContext.save()

        // R-B2: 异步清理检查点和备份文件，不阻塞 session 删除本身
        if let gc = checkpointGCService {
            Task {
                await gc.purgeSession(sessionID: sessionID, modelContext: modelContext)
            }
        }
    }

    // ... deleteAllSessions 类似处理 ...
}
```

> **注意：** `deleteAllSessions` 中也需要在每次 `modelContext.delete(session)` 之后记录 sessionID，最后批量 purge。可参考如下模式：

```swift
    func deleteAllSessions(
        modelContext: ModelContext,
        sessions explicitSessions: [Session]? = nil,
        batchSize: Int = 50
    ) async {
        let sessions = explicitSessions ?? ((try? modelContext.fetch(FetchDescriptor<Session>())) ?? [])
        let effectiveBatchSize = max(1, batchSize)
        var pendingDeletes = 0
        var purgedIDs: [String] = []

        for session in sessions {
            guard SessionInteractionPolicy(session: session).canDelete else { continue }
            let sid = session.sessionId
            pruneChannelResources(for: session, modelContext: modelContext)
            modelContext.delete(session)
            purgedIDs.append(sid)
            pendingDeletes += 1

            if pendingDeletes == effectiveBatchSize {
                try? modelContext.save()
                pendingDeletes = 0
                await Task.yield()
            }
        }

        if pendingDeletes > 0 {
            try? modelContext.save()
        }

        // R-B2: 批量 purge（异步，不阻塞调用方）
        if let gc = checkpointGCService {
            for sid in purgedIDs {
                await gc.purgeSession(sessionID: sid, modelContext: modelContext)
            }
        }
    }
```

**Step 4：运行集成测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests/sessionDeletion_triggersCheckpointPurge \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -20
```

预期：1 个测试 passed。

**Step 5：提交**

```bash
git add agentGui/Services/Channels/SessionDeletionCoordinator.swift \
        agentGuiTests/CheckpointGCServiceTests.swift
git commit -m "feat(R-B2): hook CheckpointGCService.purgeSession into SessionDeletionCoordinator"
```

---

## Task 5：App 启动接入 + `SessionDeletionCoordinator` 注入点更新

在 app 启动时异步调用 `CheckpointGCService.pruneAllSessions`，同时更新 `SessionDeletionCoordinator` 的实际调用站点，注入共享 GC 实例。

**Files:**
- Modify: `agentGui/agentGuiApp.swift`（或数据层初始化点）
- Modify: 调用 `SessionDeletionCoordinator()` 的所有站点——确认调用方

### Step 1：找出所有 `SessionDeletionCoordinator()` 调用站点

```bash
grep -rn "SessionDeletionCoordinator()" \
  agentGui/ --include="*.swift"
```

逐一修改为 `SessionDeletionCoordinator(checkpointGCService: sharedGCService)`。如果调用站点位于 `@MainActor` 的 ViewModel / View，可从环境或依赖注入链获取共享实例。

**推荐：** 在 `agentGuiApp.swift` 中定义共享 GC 服务单例（懒加载）：

```swift
// 在 agentGuiApp 顶层（@main struct 外或 @StateObject 内）
private let sharedCheckpointGCService = CheckpointGCService()
```

### Step 2：app 启动时触发 GC

在 `agentGuiApp.swift` 的 `body` 或 `init` 中：

```swift
.task {
    // 低优先级后台 GC，不影响 UI 启动
    await Task.detached(priority: .utility) {
        await sharedCheckpointGCService.pruneAllSessions(modelContext: modelContext)
    }.value
}
```

如果 `modelContext` 在 app body 中通过 `@Environment(\.modelContext)` 获取，则在 `WindowGroup` 的 `onAppear` 或 `.task` modifier 中触发。

### Step 3：手动验证

1. 运行 app，在模拟器中创建几个 session 并生成检查点（通过 R-A3/B1 hook）。
2. 删除其中一个 session，通过日志或 `~/.agentgui/checkpoints/` 目录变化确认 GC 执行。
3. 退出 app 重启，确认 GC 日志在启动路径中出现。

### Step 4：运行所有 R-B2 测试（全部通过后提交）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-rb2-gc-derived \
  -only-testing:agentGuiTests/CheckpointGCServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error:" | head -40
```

预期：全部 passed（共 7 个测试）。

**Step 5：提交**

```bash
git add agentGui/agentGuiApp.swift \
        agentGui/Services/Channels/SessionDeletionCoordinator.swift
git commit -m "feat(R-B2): wire CheckpointGCService into app startup + SessionDeletionCoordinator injection points"
```

---

## 验收标准检查表

完成所有 Task 后，对照设计文档的验收标准：

- [ ] **长期不增长**：模拟 200 次提交后（`evictOldCheckpoints(maxCheckpoints:50)` 多次调用），`ConversationCheckpoint` 记录数 ≤ 50 × session 数
- [ ] **孤立文件清理**：`pruneOrphanBackupFiles` 调用后，`~/.agentgui/checkpoints/{sessionID}/` 中不存在无引用的 `.bak` 文件
- [ ] **session 删除清理**：`SessionDeletionCoordinator.delete` 执行后，对应 session 的检查点记录和磁盘目录均消失
- [ ] **隔离性**：对 session A 的清理操作不影响 session B 的检查点和备份文件
- [ ] **幂等**：`pruneOrphanBackupFiles` 对同一 session 连续调用两次，第二次无副作用

---

## 文件变更清单

| 操作 | 文件 |
|------|------|
| Create | `agentGui/Services/Rewind/CheckpointGCService.swift` |
| Create | `agentGuiTests/CheckpointGCServiceTests.swift` |
| Modify | `agentGui/Services/Channels/SessionDeletionCoordinator.swift` |
| Modify | `agentGui/agentGuiApp.swift`（或数据初始化点） |
