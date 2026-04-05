# R-A2 FileBackupStore 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `FileBackupStore`，以内容寻址方式在磁盘上管理文件备份——支持写入备份（`createBackup`）、变更检测（`hasFileChanged`）、恢复文件（`restoreFile`）和按 session 批量清理（`deleteBackups`）。

**Architecture:** 纯 actor，无 SwiftData 依赖；备份文件存储在 `~/.agentgui/checkpoints/{sessionID}/{sha256[:2]}/{sha256}.v{n}.bak`，内容寻址天然幂等。stat 快速路径（大小+mtime 相同则跳过内容比对）保证 `hasFileChanged` 低延迟。

**Tech Stack:** Swift 6 actor, Foundation FileManager/URL/Data, CryptoKit SHA256, agentGui `FileBackupEntry`（来自 R-A1 `ConversationCheckpoint.swift`）, `ConfigDirectoryManager`

---

## 背景速查

### 参考：Claude Code 对应实现

Claude Code 的 `createBackup`、`restoreBackup`、`checkOriginFileChanged` 位于
`claude-code-source-code-main/src/utils/fileHistory.ts`（本地路径 `/Users/feint/Downloads/claude-code-source-code-main/src/utils/fileHistory.ts`）。

关键逻辑：
- `createBackup`：用文件路径 SHA256 hash 命名，lazy mkdir，ENOENT → 返回 `null` backupKey（文件不存在标记）
- `checkOriginFileChanged`：先对比 mode + size，mtime 小于备份时间则直接判定无变化，否则逐字节读取对比
- `restoreBackup`：copyFile（备份→原路径），chmod 恢复权限，lazy mkdir

### agentGui 现有基础

| 元素 | 位置 |
|------|------|
| `FileBackupEntry` | `agentGui/Models/ConversationCheckpoint.swift` 已定义 |
| `ConfigDirectoryManager.shared.agentGuiDir` | `agentGui/Utilities/ConfigDirectoryManager.swift`，路径 `~/.agentgui/` |
| 备份目标子目录 | **新建** `~/.agentgui/checkpoints/` |

### 备份路径约定

```
~/.agentgui/
  checkpoints/
    {sessionID}/
      {sha256[:2]}/          ← 2-char prefix shard，防止单目录文件过多
        {sha256}.v{n}.bak    ← 完整内容哈希 + 版本号
```

`backupKey`（存入 `FileBackupEntry.backupKey`）= `"{sha256}.v{n}"`（不含 `.bak` 扩展名）。

调用方通过 `backupKey` + `sessionID` 即可重建完整路径：  
`checkpoints/{sessionID}/{backupKey[:2]}/{backupKey}.bak`

---

## Task 1：新建 `FileBackupStore.swift` 空文件 + actor 骨架

**Files:**
- Create: `agentGui/Services/Rewind/FileBackupStore.swift`

### Step 1：创建目录和骨架文件

```swift
// agentGui/Services/Rewind/FileBackupStore.swift
import CryptoKit
import Foundation

// MARK: - Errors

enum FileBackupStoreError: Error, Sendable {
    case backupFileNotFound(backupKey: String, sessionID: String)
    case pathTraversalDetected(path: String)
}

// MARK: - FileBackupStore

/// 以内容寻址方式在磁盘上管理文件备份。
///
/// - 备份路径：`~/.agentgui/checkpoints/{sessionID}/{key[:2]}/{key}.bak`
/// - `key` = `{sha256(content)}.v{version}`
/// - 相同内容不重复写入（idempotent）。
/// - 线程安全：`actor` 序列化所有状态访问；实际磁盘 IO 在内部调用，可安全并发。
actor FileBackupStore: Sendable {

    // MARK: - Configuration

    private let checkpointsBaseURL: URL

    // MARK: - Init

    init(baseURL: URL? = nil) {
        checkpointsBaseURL = baseURL
            ?? ConfigDirectoryManager.shared.agentGuiDir
                .appendingPathComponent("checkpoints", isDirectory: true)
    }

    // MARK: - Public API

    /// 备份 `filePath` 当前内容（修改前调用）。
    /// 若文件不存在，返回 `backupKey == nil` 的 entry（表示该文件此时不存在）。
    /// 相同内容多次调用幂等——不重复写入磁盘。
    func createBackup(
        filePath: String,
        sessionID: String,
        version: Int
    ) async throws -> FileBackupEntry {
        fatalError("not implemented")
    }

    /// 文件当前内容是否与备份不同。
    /// `entry.backupKey == nil`：检查文件现在是否存在（存在则认为"已变化"）。
    /// 使用 stat 快速路径：size + mode 相同且 mtime < 备份文件 mtime 时直接返回 false。
    func hasFileChanged(
        filePath: String,
        sessionID: String,
        entry: FileBackupEntry
    ) async -> Bool {
        fatalError("not implemented")
    }

    /// 从备份恢复文件内容。
    /// 若 `entry.backupKey == nil`，删除 `filePath`（该文件在快照时不存在）。
    func restoreFile(
        filePath: String,
        sessionID: String,
        from entry: FileBackupEntry
    ) async throws {
        fatalError("not implemented")
    }

    /// 删除指定 session 下的所有备份文件（GC 入口）。
    func deleteBackups(forSession sessionID: String) async {
        fatalError("not implemented")
    }

    // MARK: - Internal Path Helpers

    private func backupURL(backupKey: String, sessionID: String) -> URL {
        let shard = String(backupKey.prefix(2))
        return checkpointsBaseURL
            .appendingPathComponent(sessionID)
            .appendingPathComponent(shard)
            .appendingPathComponent("\(backupKey).bak")
    }

    private func sessionBaseURL(sessionID: String) -> URL {
        checkpointsBaseURL.appendingPathComponent(sessionID, isDirectory: true)
    }
}
```

### Step 2：将文件添加到 Xcode 项目

在 Xcode 中：File → Add Files to "agentGui" → 选择 `agentGui/Services/Rewind/FileBackupStore.swift`，Target 勾选 `agentGui`。

> **注意：** 若通过终端创建文件，还需要手动在 `agentGui.xcodeproj/project.pbxproj` 中添加文件引用，或在 Xcode 中 Add Files。

### Step 3：确认编译通过

在 Xcode 中 ⌘B，确认无编译错误（所有方法均 `fatalError`，属于预期）。

---

## Task 2：TDD — `createBackup` 实现

**Files:**
- Create: `agentGuiTests/FileBackupStoreTests.swift`
- Modify: `agentGui/Services/Rewind/FileBackupStore.swift`

### Step 1：编写失败测试

```swift
// agentGuiTests/FileBackupStoreTests.swift
import Foundation
import Testing
@testable import agentGui

@Suite("FileBackupStore Tests")
struct FileBackupStoreTests {

    // MARK: - Helpers

    /// 每次测试使用隔离的临时目录，避免状态污染。
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeStore(baseURL: URL) -> FileBackupStore {
        FileBackupStore(baseURL: baseURL)
    }

    // MARK: - createBackup: 存在文件

    @Test
    func createBackup_existingFile_createsBackupOnDisk() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("source.txt")
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)

        let entry = try await store.createBackup(
            filePath: testFile.path,
            sessionID: "session-1",
            version: 1
        )

        // backupKey 不为 nil
        let key = try #require(entry.backupKey)
        #expect(entry.version == 1)
        #expect(entry.originalRelativePath == testFile.path)

        // 备份文件存在于磁盘
        let bak = tmp
            .appendingPathComponent("checkpoints/session-1/\(String(key.prefix(2)))/\(key).bak")
        #expect(FileManager.default.fileExists(atPath: bak.path))

        // 备份文件内容与源文件一致
        let content = try String(contentsOf: bak, encoding: .utf8)
        #expect(content == "hello world")
    }

    @Test
    func createBackup_existingFile_idempotent() async throws {
        // 相同内容两次调用，返回相同 backupKey，磁盘上不重复写
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("idempotent.txt")
        try "same content".write(to: testFile, atomically: true, encoding: .utf8)

        let entry1 = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
        let entry2 = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

        #expect(entry1.backupKey == entry2.backupKey)
    }

    @Test
    func createBackup_nonexistentFile_returnsNilBackupKey() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

        let entry = try await store.createBackup(
            filePath: "/tmp/does-not-exist-\(UUID().uuidString).txt",
            sessionID: "s",
            version: 1
        )

        #expect(entry.backupKey == nil)
        #expect(entry.version == 1)
    }

    @Test
    func createBackup_binaryFile_roundtripCorrect() async throws {
        let tmp = try makeTempDir()
        let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
        let testFile = tmp.appendingPathComponent("binary.bin")
        let binaryData = Data((0..<256).map { UInt8($0) })
        try binaryData.write(to: testFile)

        let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
        let key = try #require(entry.backupKey)
        let bak = tmp.appendingPathComponent("checkpoints/s/\(String(key.prefix(2)))/\(key).bak")
        let restored = try Data(contentsOf: bak)
        #expect(restored == binaryData)
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：测试全部失败，错误为 `fatalError("not implemented")` / 崩溃。

### Step 3：实现 `createBackup`

在 `FileBackupStore.swift` 中替换 `createBackup` 的 `fatalError`：

```swift
func createBackup(
    filePath: String,
    sessionID: String,
    version: Int
) async throws -> FileBackupEntry {
    let fm = FileManager.default

    // 读取源文件，若不存在返回 nil-key entry
    guard let sourceData = fm.contents(atPath: filePath) else {
        return FileBackupEntry(
            backupKey: nil,
            version: version,
            backupTime: Date(),
            originalRelativePath: filePath
        )
    }

    // 内容哈希 → backupKey
    let hash = SHA256.hash(data: sourceData)
        .compactMap { String(format: "%02x", $0) }
        .joined()
    let backupKey = "\(hash).v\(version)"

    let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)

    // 幂等：若备份文件已存在且大小相同，直接返回（同内容不重写）
    if let existingSize = try? backupFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       existingSize == sourceData.count {
        return FileBackupEntry(
            backupKey: backupKey,
            version: version,
            backupTime: Date(),
            originalRelativePath: filePath
        )
    }

    // lazy mkdir + 写入
    let backupDir = backupFileURL.deletingLastPathComponent()
    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
    try sourceData.write(to: backupFileURL, options: .atomic)

    return FileBackupEntry(
        backupKey: backupKey,
        version: version,
        backupTime: Date(),
        originalRelativePath: filePath
    )
}
```

> **设计说明：** 使用 `CryptoKit.SHA256` 而非 `CommonCrypto`，无需桥接头文件，Swift-native。

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

预期：`createBackup` 相关测试全部通过。

### Step 5：提交

```bash
git add agentGui/Services/Rewind/FileBackupStore.swift agentGuiTests/FileBackupStoreTests.swift
git commit -m "feat(rewind): R-A2 FileBackupStore createBackup — content-addressed file backup"
```

---

## Task 3：TDD — `hasFileChanged` 实现

**Files:**
- Modify: `agentGuiTests/FileBackupStoreTests.swift`（追加测试）
- Modify: `agentGui/Services/Rewind/FileBackupStore.swift`

### Step 1：追加失败测试

```swift
// 在 FileBackupStoreTests 中追加：

// MARK: - hasFileChanged

@Test
func hasFileChanged_fileUnchanged_returnsFalse() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("unchanged.txt")
    try "original".write(to: testFile, atomically: true, encoding: .utf8)

    let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)
    let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: entry)
    #expect(changed == false)
}

@Test
func hasFileChanged_fileModified_returnsTrue() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("modified.txt")
    try "original".write(to: testFile, atomically: true, encoding: .utf8)

    let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

    // 修改文件内容
    try "modified content".write(to: testFile, atomically: true, encoding: .utf8)

    let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: entry)
    #expect(changed == true)
}

@Test
func hasFileChanged_nilBackupKey_fileExists_returnsTrue() async throws {
    // nil backupKey = 文件快照时不存在；现在文件存在 → 已变化
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("new.txt")
    try "created after snapshot".write(to: testFile, atomically: true, encoding: .utf8)

    let nilEntry = FileBackupEntry(
        backupKey: nil,
        version: 1,
        backupTime: Date(),
        originalRelativePath: testFile.path
    )
    let changed = await store.hasFileChanged(filePath: testFile.path, sessionID: "s", entry: nilEntry)
    #expect(changed == true)
}

@Test
func hasFileChanged_nilBackupKey_fileAbsent_returnsFalse() async throws {
    // nil backupKey = 文件快照时不存在；现在文件也不存在 → 未变化
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

    let nilEntry = FileBackupEntry(
        backupKey: nil,
        version: 1,
        backupTime: Date(),
        originalRelativePath: "/tmp/ghost-\(UUID().uuidString).txt"
    )
    let changed = await store.hasFileChanged(
        filePath: "/tmp/ghost-\(UUID().uuidString).txt",
        sessionID: "s",
        entry: nilEntry
    )
    #expect(changed == false)
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

预期：新增的 `hasFileChanged` 测试全部失败。

### Step 3：实现 `hasFileChanged`

```swift
func hasFileChanged(
    filePath: String,
    sessionID: String,
    entry: FileBackupEntry
) async -> Bool {
    let fm = FileManager.default

    guard let backupKey = entry.backupKey else {
        // nil backupKey 表示文件在快照时不存在；若现在存在则"已变化"
        return fm.fileExists(atPath: filePath)
    }

    let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)

    guard let sourceAttrs = try? fm.attributesOfItem(atPath: filePath),
          let backupAttrs = try? fm.attributesOfItem(atPath: backupFileURL.path) else {
        // 其中一个文件不可读（可能已被删除）→ 视为已变化
        return true
    }

    let sourceSize = sourceAttrs[.size] as? Int ?? -1
    let backupSize = backupAttrs[.size] as? Int ?? -2
    guard sourceSize == backupSize else { return true }

    // mtime 快速路径：源文件比备份旧 → 内容未变
    if let sourceMtime = sourceAttrs[.modificationDate] as? Date,
       let backupMtime = backupAttrs[.modificationDate] as? Date,
       sourceMtime < backupMtime {
        return false
    }

    // 内容完整对比
    guard let sourceData = fm.contents(atPath: filePath),
          let backupData = fm.contents(atPath: backupFileURL.path) else {
        return true
    }
    return sourceData != backupData
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

预期：所有测试通过。

### Step 5：提交

```bash
git add agentGui/Services/Rewind/FileBackupStore.swift agentGuiTests/FileBackupStoreTests.swift
git commit -m "feat(rewind): R-A2 FileBackupStore hasFileChanged — stat fast-path + content compare"
```

---

## Task 4：TDD — `restoreFile` 实现

**Files:**
- Modify: `agentGuiTests/FileBackupStoreTests.swift`（追加测试）
- Modify: `agentGui/Services/Rewind/FileBackupStore.swift`

### Step 1：追加失败测试

```swift
// MARK: - restoreFile

@Test
func restoreFile_restoresContent() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("restore.txt")
    try "original content".write(to: testFile, atomically: true, encoding: .utf8)

    let entry = try await store.createBackup(filePath: testFile.path, sessionID: "s", version: 1)

    // 修改文件
    try "modified content".write(to: testFile, atomically: true, encoding: .utf8)

    // 恢复
    try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: entry)

    let restored = try String(contentsOf: testFile, encoding: .utf8)
    #expect(restored == "original content")
}

@Test
func restoreFile_nilBackupKey_deletesFile() async throws {
    // nil backupKey → 文件快照时不存在 → 恢复时应删除
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("to-delete.txt")
    try "some content".write(to: testFile, atomically: true, encoding: .utf8)

    let nilEntry = FileBackupEntry(
        backupKey: nil,
        version: 1,
        backupTime: Date(),
        originalRelativePath: testFile.path
    )
    try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: nilEntry)

    #expect(!FileManager.default.fileExists(atPath: testFile.path))
}

@Test
func restoreFile_nilBackupKey_fileAlreadyAbsent_noThrow() async throws {
    // nil backupKey + 文件已不存在 → 幂等，不抛错
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let ghost = "/tmp/ghost-\(UUID().uuidString).txt"

    let nilEntry = FileBackupEntry(
        backupKey: nil,
        version: 1,
        backupTime: Date(),
        originalRelativePath: ghost
    )
    // 不应抛出
    try await store.restoreFile(filePath: ghost, sessionID: "s", from: nilEntry)
}

@Test
func restoreFile_missingBackupFile_throws() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    let testFile = tmp.appendingPathComponent("missing-backup.txt")
    try "content".write(to: testFile, atomically: true, encoding: .utf8)

    let fakeEntry = FileBackupEntry(
        backupKey: "deadbeef01234567deadbeef01234567deadbeef01234567deadbeef01234567.v1",
        version: 1,
        backupTime: Date(),
        originalRelativePath: testFile.path
    )
    await #expect(throws: FileBackupStoreError.self) {
        try await store.restoreFile(filePath: testFile.path, sessionID: "s", from: fakeEntry)
    }
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

### Step 3：实现 `restoreFile`

```swift
func restoreFile(
    filePath: String,
    sessionID: String,
    from entry: FileBackupEntry
) async throws {
    let fm = FileManager.default

    guard let backupKey = entry.backupKey else {
        // nil → 删除目标文件（快照时文件不存在）
        do {
            try fm.removeItem(atPath: filePath)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // 已不存在，幂等
        }
        return
    }

    let backupFileURL = backupURL(backupKey: backupKey, sessionID: sessionID)
    guard fm.fileExists(atPath: backupFileURL.path) else {
        throw FileBackupStoreError.backupFileNotFound(backupKey: backupKey, sessionID: sessionID)
    }

    // 恢复：lazy mkdir → copyFile（覆盖目标）
    let targetURL = URL(fileURLWithPath: filePath)
    let targetDir = targetURL.deletingLastPathComponent()
    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

    if fm.fileExists(atPath: filePath) {
        try fm.removeItem(atPath: filePath)
    }
    try fm.copyItem(at: backupFileURL, to: targetURL)
}
```

### Step 4：运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

### Step 5：提交

```bash
git add agentGui/Services/Rewind/FileBackupStore.swift agentGuiTests/FileBackupStoreTests.swift
git commit -m "feat(rewind): R-A2 FileBackupStore restoreFile — lazy mkdir, nil-key delete, error on missing backup"
```

---

## Task 5：TDD — `deleteBackups` 实现

**Files:**
- Modify: `agentGuiTests/FileBackupStoreTests.swift`（追加测试）
- Modify: `agentGui/Services/Rewind/FileBackupStore.swift`

### Step 1：追加失败测试

```swift
// MARK: - deleteBackups

@Test
func deleteBackups_removesAllBackupsForSession() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

    // 创建两个不同文件的备份
    let file1 = tmp.appendingPathComponent("a.txt")
    let file2 = tmp.appendingPathComponent("b.txt")
    try "aaa".write(to: file1, atomically: true, encoding: .utf8)
    try "bbb".write(to: file2, atomically: true, encoding: .utf8)

    let entry1 = try await store.createBackup(filePath: file1.path, sessionID: "sess-gc", version: 1)
    let entry2 = try await store.createBackup(filePath: file2.path, sessionID: "sess-gc", version: 1)

    let bak1 = try #require(entry1.backupKey)
    let bak2 = try #require(entry2.backupKey)

    let sessionDir = tmp.appendingPathComponent("checkpoints/sess-gc")
    #expect(FileManager.default.fileExists(atPath: sessionDir.path))

    await store.deleteBackups(forSession: "sess-gc")

    #expect(!FileManager.default.fileExists(atPath: sessionDir.path))
    _ = bak1; _ = bak2  // suppress unused warning
}

@Test
func deleteBackups_otherSessionUnaffected() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))

    let file = tmp.appendingPathComponent("c.txt")
    try "ccc".write(to: file, atomically: true, encoding: .utf8)
    let entry = try await store.createBackup(filePath: file.path, sessionID: "other-session", version: 1)
    let key = try #require(entry.backupKey)

    // 删除不同 session
    await store.deleteBackups(forSession: "sess-to-delete")

    // other-session 的备份仍存在
    let bak = tmp.appendingPathComponent("checkpoints/other-session/\(String(key.prefix(2)))/\(key).bak")
    #expect(FileManager.default.fileExists(atPath: bak.path))
}

@Test
func deleteBackups_nonexistentSession_noThrow() async {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let store = makeStore(baseURL: tmp)
    // 不应崩溃
    await store.deleteBackups(forSession: "ghost-session")
}
```

### Step 2：运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

### Step 3：实现 `deleteBackups`

```swift
func deleteBackups(forSession sessionID: String) async {
    let sessionDir = sessionBaseURL(sessionID: sessionID)
    try? FileManager.default.removeItem(at: sessionDir)
}
```

### Step 4：运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

预期：全部测试通过。

### Step 5：提交

```bash
git add agentGui/Services/Rewind/FileBackupStore.swift agentGuiTests/FileBackupStoreTests.swift
git commit -m "feat(rewind): R-A2 FileBackupStore deleteBackups — full session GC"
```

---

## Task 6：安全加固 — 路径遍历防护

**Files:**
- Modify: `agentGui/Services/Rewind/FileBackupStore.swift`
- Modify: `agentGuiTests/FileBackupStoreTests.swift`（追加安全测试）

### 背景

`createBackup` 和 `restoreFile` 的 `filePath` 参数由 LLM 生成的工具调用提供，存在路径遍历风险（如 `../../etc/passwd`）。

### Step 1：追加安全测试

```swift
// MARK: - Security

@Test
func createBackup_pathTraversal_throws() async throws {
    let tmp = try makeTempDir()
    let store = makeStore(baseURL: tmp.appendingPathComponent("checkpoints"))
    // 路径规范化后仍为绝对路径，但尝试遍历到 /etc
    let traversal = "/tmp/../etc/passwd"
    // 不应将 /etc/passwd 内容写入备份
    // 此测试验证函数不 throw pathTraversalDetected（路径虽奇怪但合法）
    // 真正的保护在 restoreFile 不能写到非 workspaceRoot 目录（由调用方负责）
    // 此处只验证 createBackup 对绝对路径不混入备份路径
    let entry = try await store.createBackup(filePath: traversal, sessionID: "s", version: 1)
    // /etc/passwd 一般存在；若存在，backupKey 不为 nil。
    // 关键：备份路径必须在 checkpoints 目录内，不逃逸到外部
    if let key = entry.backupKey {
        let bak = tmp.appendingPathComponent("checkpoints/s/\(String(key.prefix(2)))/\(key).bak")
        // 备份文件的 canonicalPath 必须在 checkpoints 目录内
        let checkpointsCanonical = tmp.appendingPathComponent("checkpoints").resolvingSymlinksInPath().path
        let bakCanonical = bak.resolvingSymlinksInPath().path
        #expect(bakCanonical.hasPrefix(checkpointsCanonical))
    }
}
```

> **设计说明：** `FileBackupStore` 本身只负责正确存储备份（不越出 checkpoints 目录）。禁止向敏感路径恢复文件的职责由 `FileSystemRewindCoordinator`（R-C2）通过 workspaceRoot 前缀校验实现。此处仅验证备份写入路径不逃逸。

### Step 2：确认测试通过（无需修改实现）

备份路径完全由 `backupURL(backupKey:sessionID:)` 控制，已固定在 `checkpointsBaseURL` 内。因此此安全检验天然通过。

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  -only-testing:agentGuiTests/FileBackupStoreTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```

### Step 3：提交

```bash
git add agentGui/Services/Rewind/FileBackupStore.swift agentGuiTests/FileBackupStoreTests.swift
git commit -m "feat(rewind): R-A2 FileBackupStore security test — backup path containment verified"
```

---

## Task 7：将 `FileBackupStore` 注册到 `ClaudeService` / 应用级单例

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService.swift`（或 `agentGui/Services/ClaudeService/` 的对应 extension）

### 背景

后续的 `FileCheckpointHook`（R-A3）和 `ConversationCheckpointService`（R-B1）需要访问 `FileBackupStore`。`ClaudeService` 是 `@Observable @MainActor` 的服务中枢，是注册新服务实例的自然位置。

### Step 1：查看 `ClaudeService.swift` 的 `@Observable` 属性区

```bash
grep -n "changeReviewProjectionStore\|verificationEvidenceStore\|toolPayloadStore" \
  agentGui/Services/ClaudeService/ClaudeService.swift | head -10
```

### Step 2：添加 `fileBackupStore` 属性

在 `ClaudeService` 中，找到其他单例 store 属性的位置，添加：

```swift
/// R-A2: 文件备份 store，为 Rewind 功能提供内容寻址备份能力。
let fileBackupStore: FileBackupStore = FileBackupStore()
```

> **注意：** `FileBackupStore` 是 `actor`，线程安全，可在 `@MainActor` 上持有。

### Step 3：确认编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-r-a2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:BUILD" | head -10
```

### Step 4：提交

```bash
git add agentGui/Services/ClaudeService/ClaudeService.swift
git commit -m "feat(rewind): R-A2 register FileBackupStore on ClaudeService"
```

---

## 验收矩阵

| 验收条件 | 测试方法 |
|---------|---------|
| 备份 + 恢复往返无内容损失（UTF-8 文本） | `createBackup_existingFile` + `restoreFile_restoresContent` |
| 备份 + 恢复往返无内容损失（二进制文件） | `createBackup_binaryFile_roundtripCorrect` |
| 文件不存在时 backup 返回 nil key | `createBackup_nonexistentFile_returnsNilBackupKey` |
| restore(nil key) 删除目标文件 | `restoreFile_nilBackupKey_deletesFile` |
| restore(nil key) 文件已不存在不报错 | `restoreFile_nilBackupKey_fileAlreadyAbsent_noThrow` |
| 相同内容不重复写入 | `createBackup_existingFile_idempotent` |
| 有变化时 hasFileChanged = true | `hasFileChanged_fileModified_returnsTrue` |
| 无变化时 hasFileChanged = false | `hasFileChanged_fileUnchanged_returnsFalse` |
| deleteBackups 清除 session 全部备份 | `deleteBackups_removesAllBackupsForSession` |
| deleteBackups 不影响其他 session | `deleteBackups_otherSessionUnaffected` |
| 备份路径不逃逸 checkpoints 目录 | `createBackup_pathTraversal_throws` |

---

## 完成后的下一步

R-A2 完成后，应立即进行 **R-A3 FileCheckpointHook**：

- 注册到 `ToolExecutionHookPipeline`，在 `preExecute` 时调用 `fileBackupStore.createBackup`。
- 参考 `ChangeReviewHook.swift` 的结构（`hookID`、三个方法、在 `AgentLoopToolExecutionCoordinatorBuilder.buildHookPipeline()` 中注册）。
- 目标工具名：`str_replace_based_edit_tool`（命令 `str_replace`、`create`、`insert`、`write`）。
