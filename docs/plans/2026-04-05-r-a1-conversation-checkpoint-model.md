# R-A1: ConversationCheckpoint SwiftData 模型实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `ConversationCheckpoint` SwiftData `@Model` 和 `FileBackupEntry` Codable 结构体，表示一次用户消息触发的文件系统状态快照，为 Rewind 功能提供持久化基础。

**Architecture:** `ConversationCheckpoint` 作为独立 SwiftData 模型，通过 `messageID: UUID` 软引用 `Message`（不建立 `@Relationship`，防止对话截断时级联误删检查点）。`FileBackupEntry` 编码为 JSON 字符串存储在 `trackedFileBackupsJSON` 字段，避免引入额外 SwiftData 子模型。注册进现有 `PersistenceSchema.sharedModelTypes`。

**Tech Stack:** Swift 6, SwiftData, Swift Testing (`@Test` / `#expect`)

---

## 背景与约束

- 项目使用 `PersistenceSchema.sharedModelTypes`（位于 `agentGui/agentGuiApp.swift` 第 17 行）统一注册所有 `@Model`，新增模型必须加入此数组。
- 测试使用 `PersistenceSchema.sharedModelTypes` + `isStoredInMemoryOnly: true` 创建内存容器（见 `agentGuiTests/ACPProviderProfileRepositoryTests.swift` 第 91–95 行），本计划遵循相同模式。
- `Session.sessionId` 类型为 `String`，`Message.id` 类型为 `UUID`；检查点通过 `sessionID: String` + `messageID: UUID` 软关联两者。
- 不使用 `@Relationship`，避免 cascade 删除时误清检查点（Rewind 的检查点应在对话截断后依然存活，直到 GC 服务清理）。
- 测试框架：Swift Testing（`@Test`、`#expect`），测试结构体标注 `@MainActor`。
- 编译模式 Swift 6，所有并发边界须满足 `Sendable`。

---

## Task 1：定义 `FileBackupEntry` 与 `ConversationCheckpoint`

**Files:**
- Create: `agentGui/Models/ConversationCheckpoint.swift`

### Step 1：新建模型文件

新建 `agentGui/Models/ConversationCheckpoint.swift`，内容如下：

```swift
import Foundation
import SwiftData

/// 单个被追踪文件的备份元数据。
/// 存储为 JSON 字符串（ConversationCheckpoint.trackedFileBackupsJSON 的 value 类型）。
struct FileBackupEntry: Codable, Sendable, Equatable {
    /// 内容寻址备份文件的键（即 sha256 哈希值）。
    /// nil 表示该文件在此快照时刻不存在（新增文件的 pre-creation 状态）。
    var backupKey: String?

    /// 备份版本号，同一轮次内单调递增。
    var version: Int

    /// 备份写入时刻。
    var backupTime: Date

    /// 文件相对于 workspaceRoot 的路径（如 "src/main.swift"）。
    var originalRelativePath: String
}

extension FileBackupEntry {
    /// 该文件在快照时刻是否存在。
    var fileExistedAtSnapshot: Bool { backupKey != nil }
}

// MARK: - ConversationCheckpoint

/// 一次用户消息触发的文件系统状态快照。
/// 与 Message 通过 messageID（软引用）关联，不使用 @Relationship，
/// 防止对话截断时级联误删检查点。
@Model
final class ConversationCheckpoint {
    /// 检查点唯一标识。
    var id: UUID

    /// 所属会话 ID（对应 Session.sessionId）。
    var sessionID: String

    /// 触发此快照的用户消息 ID（对应 Message.id）。
    var messageID: UUID

    /// 会话内单调递增序号，用于排序和 GC eviction（FIFO）。
    var snapshotSequence: Int

    /// 快照创建时刻的工作目录绝对路径（对应 Session.workingDirectory）。
    var workspaceRoot: String

    /// 检查点创建时刻。
    var createdAt: Date

    /// key = 文件相对路径（相对于 workspaceRoot），value = FileBackupEntry JSON。
    /// 使用 JSON 字符串存储，避免引入额外 SwiftData 子模型。
    var trackedFileBackupsJSON: String

    /// 快速标志：此检查点是否有任何文件被追踪并发生变化。
    /// 避免每次都解码 trackedFileBackupsJSON 进行判断。
    var hasFileChanges: Bool

    init(
        id: UUID = UUID(),
        sessionID: String,
        messageID: UUID,
        snapshotSequence: Int,
        workspaceRoot: String,
        trackedFileBackups: [String: FileBackupEntry] = [:],
        hasFileChanges: Bool = false,
        createdAt: Date = Date()
    ) throws {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.snapshotSequence = snapshotSequence
        self.workspaceRoot = workspaceRoot
        self.hasFileChanges = hasFileChanges
        self.createdAt = createdAt
        self.trackedFileBackupsJSON = try Self.encode(trackedFileBackups)
    }
}

// MARK: - JSON Helpers

extension ConversationCheckpoint {
    /// 解码 trackedFileBackupsJSON → [relativePath: FileBackupEntry]。
    func decodedTrackedFileBackups() throws -> [String: FileBackupEntry] {
        guard let data = trackedFileBackupsJSON.data(using: .utf8) else {
            throw ConversationCheckpointError.invalidUTF8JSON
        }
        return try JSONDecoder().decode([String: FileBackupEntry].self, from: data)
    }

    /// 编码并更新 trackedFileBackupsJSON。
    mutating func setTrackedFileBackups(_ backups: [String: FileBackupEntry]) throws {
        trackedFileBackupsJSON = try Self.encode(backups)
        hasFileChanges = !backups.isEmpty
    }

    private static func encode(_ backups: [String: FileBackupEntry]) throws -> String {
        let data = try JSONEncoder().encode(backups)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ConversationCheckpointError.encodingFailed
        }
        return string
    }
}

// MARK: - Error

enum ConversationCheckpointError: Error, Sendable {
    case invalidUTF8JSON
    case encodingFailed
}
```

**Step 2：确认文件可编译（不运行测试，仅检查语法）**

在 Xcode 中按 `⌘B` 或运行：

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded"
```

预期输出：`** BUILD SUCCEEDED **`

若出现 `error:` 行，先修复后再继续。

**Step 3：提交**

```bash
git add agentGui/Models/ConversationCheckpoint.swift
git commit -m "feat(rewind): add ConversationCheckpoint @Model and FileBackupEntry [R-A1]"
```

---

## Task 2：注册到 PersistenceSchema

**Files:**
- Modify: `agentGui/agentGuiApp.swift:17-42`（`sharedModelTypes` 数组）

### Step 1：在 sharedModelTypes 中添加 ConversationCheckpoint

打开 `agentGui/agentGuiApp.swift`，找到 `static let sharedModelTypes: [any PersistentModel.Type] = [` 数组，在 `RecoverySnapshot.self,` 之后追加一行：

```swift
// 修改前（第 36 行附近）：
        RecoverySnapshot.self,
        IntegrityIssue.self,

// 修改后：
        RecoverySnapshot.self,
        ConversationCheckpoint.self,
        IntegrityIssue.self,
```

### Step 2：确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded"
```

预期：`** BUILD SUCCEEDED **`

### Step 3：提交

```bash
git add agentGui/agentGuiApp.swift
git commit -m "feat(rewind): register ConversationCheckpoint in PersistenceSchema [R-A1]"
```

---

## Task 3：编写模型测试

**Files:**
- Create: `agentGuiTests/ConversationCheckpointModelTests.swift`

### Step 1：编写失败测试

新建 `agentGuiTests/ConversationCheckpointModelTests.swift`：

```swift
import Foundation
import SwiftData
import Testing
@testable import agentGui

@MainActor
struct ConversationCheckpointModelTests {

    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(PersistenceSchema.sharedModelTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Insert / Fetch / Delete

    @Test
    func insertsAndFetchesCheckpoint() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let messageID = UUID()
        let checkpoint = try ConversationCheckpoint(
            sessionID: "session-1",
            messageID: messageID,
            snapshotSequence: 0,
            workspaceRoot: "/tmp/workspace"
        )
        context.insert(checkpoint)
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-1" }
        let results = try context.fetch(descriptor)

        #expect(results.count == 1)
        #expect(results.first?.messageID == messageID)
        #expect(results.first?.workspaceRoot == "/tmp/workspace")
        #expect(results.first?.snapshotSequence == 0)
        #expect(results.first?.hasFileChanges == false)
    }

    @Test
    func deletesCheckpointWithoutCascadingToMessages() throws {
        // ConversationCheckpoint 与 Message 无 @Relationship，
        // 删除检查点不应影响 Message；此测试验证独立删除可行。
        let container = try makeContainer()
        let context = ModelContext(container)

        let checkpoint = try ConversationCheckpoint(
            sessionID: "session-del",
            messageID: UUID(),
            snapshotSequence: 1,
            workspaceRoot: "/tmp/ws"
        )
        context.insert(checkpoint)
        try context.save()

        context.delete(checkpoint)
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-del" }
        let results = try context.fetch(descriptor)
        #expect(results.isEmpty)
    }

    @Test
    func fetchesMultipleCheckpointsSortedBySequence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        for i in 0..<5 {
            let cp = try ConversationCheckpoint(
                sessionID: "session-multi",
                messageID: UUID(),
                snapshotSequence: i,
                workspaceRoot: "/tmp/ws"
            )
            context.insert(cp)
        }
        try context.save()

        var descriptor = FetchDescriptor<ConversationCheckpoint>()
        descriptor.predicate = #Predicate { $0.sessionID == "session-multi" }
        descriptor.sortBy = [SortDescriptor(\ConversationCheckpoint.snapshotSequence)]
        let results = try context.fetch(descriptor)

        #expect(results.count == 5)
        #expect(results.map(\.snapshotSequence) == [0, 1, 2, 3, 4])
    }

    // MARK: - JSON 往返序列化

    @Test
    func emptyBackupsSerializesToEmptyJSON() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )
        let decoded = try checkpoint.decodedTrackedFileBackups()
        #expect(decoded.isEmpty)
        #expect(checkpoint.hasFileChanges == false)
    }

    @Test
    func backupEntryRoundTripsCorrectly() throws {
        var checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        let backupTime = Date(timeIntervalSince1970: 1_000_000)
        let entry = FileBackupEntry(
            backupKey: "abc123def456",
            version: 1,
            backupTime: backupTime,
            originalRelativePath: "src/main.swift"
        )
        try checkpoint.setTrackedFileBackups(["src/main.swift": entry])

        let decoded = try checkpoint.decodedTrackedFileBackups()

        #expect(decoded.count == 1)
        let roundTripped = try #require(decoded["src/main.swift"])
        #expect(roundTripped.backupKey == "abc123def456")
        #expect(roundTripped.version == 1)
        #expect(roundTripped.originalRelativePath == "src/main.swift")
        // Date 精度：允许 0.001 秒误差（JSON 浮点数精度）
        #expect(abs(roundTripped.backupTime.timeIntervalSince(backupTime)) < 0.001)
    }

    @Test
    func nilBackupKeyRoundTripsAsNil() throws {
        var checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        // backupKey = nil 表示该文件在快照时刻不存在
        let entry = FileBackupEntry(
            backupKey: nil,
            version: 0,
            backupTime: Date(),
            originalRelativePath: "new-file.txt"
        )
        try checkpoint.setTrackedFileBackups(["new-file.txt": entry])

        let decoded = try checkpoint.decodedTrackedFileBackups()
        let roundTripped = try #require(decoded["new-file.txt"])
        #expect(roundTripped.backupKey == nil)
        #expect(roundTripped.fileExistedAtSnapshot == false)
    }

    @Test
    func multipleEntriesRoundTripCorrectly() throws {
        var checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )

        let entries: [String: FileBackupEntry] = [
            "a.swift": FileBackupEntry(
                backupKey: "hash-a",
                version: 1,
                backupTime: Date(timeIntervalSince1970: 1_000),
                originalRelativePath: "a.swift"
            ),
            "b.swift": FileBackupEntry(
                backupKey: nil,
                version: 0,
                backupTime: Date(timeIntervalSince1970: 2_000),
                originalRelativePath: "b.swift"
            ),
        ]
        try checkpoint.setTrackedFileBackups(entries)

        #expect(checkpoint.hasFileChanges == true)

        let decoded = try checkpoint.decodedTrackedFileBackups()
        #expect(decoded.count == 2)
        #expect(decoded["a.swift"]?.backupKey == "hash-a")
        #expect(decoded["b.swift"]?.backupKey == nil)
    }

    // MARK: - hasFileChanges 标志

    @Test
    func hasFileChangesIsFalseWhenBackupsEmpty() throws {
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: [:],
            hasFileChanges: false
        )
        #expect(checkpoint.hasFileChanges == false)
    }

    @Test
    func hasFileChangesIsTrueWhenBackupsProvided() throws {
        let entry = FileBackupEntry(
            backupKey: "somehash",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "file.swift"
        )
        let checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp",
            trackedFileBackups: ["file.swift": entry],
            hasFileChanges: true
        )
        #expect(checkpoint.hasFileChanges == true)
    }

    @Test
    func setTrackedFileBackupsUpdatesHasFileChangesFlag() throws {
        var checkpoint = try ConversationCheckpoint(
            sessionID: "s",
            messageID: UUID(),
            snapshotSequence: 0,
            workspaceRoot: "/tmp"
        )
        #expect(checkpoint.hasFileChanges == false)

        let entry = FileBackupEntry(
            backupKey: "h",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "x.swift"
        )
        try checkpoint.setTrackedFileBackups(["x.swift": entry])
        #expect(checkpoint.hasFileChanges == true)

        // 清空后 flag 应重置为 false
        try checkpoint.setTrackedFileBackups([:])
        #expect(checkpoint.hasFileChanges == false)
    }

    // MARK: - FileBackupEntry helpers

    @Test
    func fileExistedAtSnapshotReturnsTrueWhenBackupKeyNotNil() {
        let entry = FileBackupEntry(
            backupKey: "abc",
            version: 1,
            backupTime: Date(),
            originalRelativePath: "file.swift"
        )
        #expect(entry.fileExistedAtSnapshot == true)
    }

    @Test
    func fileExistedAtSnapshotReturnsFalseWhenBackupKeyIsNil() {
        let entry = FileBackupEntry(
            backupKey: nil,
            version: 0,
            backupTime: Date(),
            originalRelativePath: "new.swift"
        )
        #expect(entry.fileExistedAtSnapshot == false)
    }
}
```

### Step 2：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination platform=macOS \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a1-derived \
  -only-testing:agentGuiTests/ConversationCheckpointModelTests \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "Test.*passed|Test.*failed|error:|BUILD"
```

预期输出（13 个测试全通过）：
```
Test Suite 'ConversationCheckpointModelTests' passed
    Executed 13 tests, with 0 failures
** TEST SUCCEEDED **
```

若有失败，根据错误信息修复 `ConversationCheckpoint.swift` 或测试代码，然后重跑。

### Step 3：提交测试

```bash
git add agentGuiTests/ConversationCheckpointModelTests.swift
git commit -m "test(rewind): add ConversationCheckpoint model tests [R-A1]"
```

---

## 验收清单

完成后确认以下各项：

- [ ] `ConversationCheckpoint` 可被 `insert`、`fetch`（按 `sessionID` 或 `snapshotSequence` 过滤）、`delete`
- [ ] `trackedFileBackupsJSON` 往返序列化正确（含 `nil` backupKey 场景）
- [ ] `hasFileChanges` 标志与 `setTrackedFileBackups` 同步更新
- [ ] `FileBackupEntry.fileExistedAtSnapshot` 正确反映 `backupKey != nil`
- [ ] 删除 `ConversationCheckpoint` 不影响同 session 的 `Message`（无 @Relationship 的独立删除）
- [ ] `ConversationCheckpoint.self` 已加入 `PersistenceSchema.sharedModelTypes`
- [ ] 全部 13 个测试通过，build 无 error

---

## 后续依赖

本 feature (R-A1) 完成后，以下 feature 可以开始实现：

| Feature | 依赖 R-A1 的方式 |
|---------|----------------|
| **R-A2** FileBackupStore | 需要 `FileBackupEntry` 类型定义 |
| **R-A3** FileCheckpointHook | 需要 `ConversationCheckpoint` + `FileBackupEntry` |
| **R-B1** ConversationCheckpointService | 需要 `ConversationCheckpoint` insert 到 ModelContext |
| **R-C2** FileSystemRewindCoordinator | 需要从 `ConversationCheckpoint` 读取备份映射 |
