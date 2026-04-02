# Feature M-06: 后台记忆整合 Daemon 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现对齐 Claude Code AutoDream 的后台记忆整合 Daemon，在满足时间（≥24h）和会话数（≥5）双门槛时，触发 consolidation subagent 将近期多个 session 的知识蒸馏并合并到持久记忆文件中。

**Architecture:**  
- `MemoryConsolidationLockManager`（nonisolated）管理文件级乐观锁，mtime = lastConsolidatedAt，body = 持有者 PID；防止多进程/并发重复整合。  
- `MemoryConsolidationScheduleGate`（nonisolated）封装双门槛检查：时间自 `lastConsolidatedAt` 起 ≥ minHours，且 SwiftData 中 `Session.updatedAt > lastConsolidatedAt` 的会话数 ≥ minSessions。  
- `MemoryConsolidationService`（使用内部 actor `MemoryConsolidationCoordinator` 保护 `isRunning` flag）作为整合编排者；通过 `ClaudeService.runNamedSubagent` 启动 consolidation subagent（专用 `WorkflowRoleDefinition`）；整合结束后由 `lockManager.commitConsolidation()` 记录完成时间。  
- `MemoryConsolidationHook`（`AgentLoopHook`，order = 92）在 `.willFinishRun / .mainAgent` 阶段 fire-and-forget 触发整合，与 `MemoryExtractionHook`（order = 90）串联但不阻塞主 loop。  
- `ConsolidationProgressState`（`@Observable @MainActor`）承载 UI 可见的整合状态（phase、文件触碰路径、turns 计数），供 Footer pill 或任务列表挂载。

**Tech Stack:** Swift 6.0+, SwiftData, SwiftAnthropic, `FileManager` async, `@Observable`, `actor`

---

## 前置依赖

M-06 依赖以下已完成的 Feature：

| Feature | 提供的能力 |
|---------|-----------|
| M-02 | `MemoryIndexWriter`、`MemoryTopicScanner`、`ConfigDirectoryManager.shared.memoryDir` |
| M-03 | `SessionMemoryExtractorService` 的 subagent 启动模式（`runNamedSubagent`）、`MemoryExtractionCoordinator` actor 防重入 |
| M-04 | （可选）freshness note 注入 |

若上述 Feature 未完成，需先完成其对应任务。

---

## 关键文件参考

在开始前，熟悉以下文件：

| 文件 | 作用 |
|-----|------|
| `agentGui/Services/Memory/MemoryIndexWriter.swift` | MEMORY.md 写入，理解话题文件格式 |
| `agentGui/Services/Memory/MemoryTopicScanner.swift` | 话题文件扫描，学习 async FileManager 模式 |
| `agentGui/Services/AgentLoopHooks/MemoryExtractionHook.swift` | fire-and-forget hook 模式，M-06 的直接模板 |
| `agentGui/Services/AgentLoopBuiltInHookFactory.swift` | 注册 hook 的位置 |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | 构建服务并注入 hook 的位置 |
| `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` | `runNamedSubagent(...)` API |
| `agentGui/Models/WorkflowRoleDefinition.swift` | subagent role 定义，M-06 需新增 `.consolidationDaemon` |
| `agentGui/Models/AppSettings.swift` | 配置字段，M-06 需添加 2 个新字段 |
| `agentGui/Models/Session.swift` | `Session.updatedAt`，用于 session 计数门槛 |
| `agentGui/Utilities/ConfigDirectoryManager.swift` | 目录路径（`memoryDir`） |

---

## Task 1：`MemoryConsolidationLockManager`

**文件:**
- Create: `agentGui/Services/Memory/MemoryConsolidationLockManager.swift`
- Test: `agentGuiTests/MemoryConsolidationLockManagerTests.swift`

锁文件：`<memoryDir>/.consolidate-lock`，mtime = lastConsolidatedAt，body = PID（与 Claude Code `consolidationLock.ts` 对齐）。

### Step 1-1: 编写失败测试

```swift
// agentGuiTests/MemoryConsolidationLockManagerTests.swift
import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationLockManagerTests {

    // MARK: - readLastConsolidatedAt

    @Test func returnsZeroWhenLockFileAbsent() async throws {
        let dir = tmpDir()
        let manager = MemoryConsolidationLockManager(memoryDir: dir)
        let t = try await manager.readLastConsolidatedAt()
        #expect(t == 0)
    }

    @Test func returnsFileMtimeAfterAcquire() async throws {
        let dir = tmpDir()
        let manager = MemoryConsolidationLockManager(memoryDir: dir)
        let before = Date.now.timeIntervalSince1970 * 1000
        let prior = try await manager.tryAcquire()
        let after = Date.now.timeIntervalSince1970 * 1000
        let last = try await manager.readLastConsolidatedAt()
        #expect(prior != nil)
        #expect(last >= before)
        #expect(last <= after + 1000)   // 1s 容差
    }

    // MARK: - tryAcquire 竞争

    @Test func acquireReturnsPriorMtime() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        // 先随意写入一个 mtime（用 rollback 写入旧 mtime）
        let prior1 = try await m.tryAcquire()   // 第一次：no prior file → prior = 0
        #expect(prior1 == 0)

        let prior2 = try await m.tryAcquire()   // 第二次：持有者是自己 → 允许重入（视为 nil 竞争失败）
        #expect(prior2 == nil)
    }

    // MARK: - rollback

    @Test func rollbackToZeroDeletesLockFile() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        _ = try await m.tryAcquire()
        try await m.rollback(to: 0)
        let t = try await manager(dir).readLastConsolidatedAt()
        #expect(t == 0)
    }

    @Test func rollbackToNonZeroRestoresMtime() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        _ = try await m.tryAcquire()
        let target = 1_700_000_000_000.0
        try await m.rollback(to: target)
        let restored = try await m.readLastConsolidatedAt()
        #expect(abs(restored - target) < 1000)   // 1s 容差（utimes 精度）
    }

    // MARK: - commitConsolidation

    @Test func commitUpdatesLastConsolidatedAt() async throws {
        let dir = tmpDir()
        let m = MemoryConsolidationLockManager(memoryDir: dir)
        let before = Date.now.timeIntervalSince1970 * 1000
        try await m.commitConsolidation()
        let after = Date.now.timeIntervalSince1970 * 1000
        let t = try await m.readLastConsolidatedAt()
        #expect(t >= before)
        #expect(t <= after + 1000)
    }

    // MARK: - helpers

    private func tmpDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m06-lock-\(UUID().uuidString)", isDirectory: true)
    }
    private func manager(_ dir: URL) -> MemoryConsolidationLockManager {
        MemoryConsolidationLockManager(memoryDir: dir)
    }
}
```

### Step 1-2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t1 \
  -only-testing:agentGuiTests/MemoryConsolidationLockManagerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：编译错误 `cannot find type 'MemoryConsolidationLockManager'`

### Step 1-3: 实现 `MemoryConsolidationLockManager`

```swift
// agentGui/Services/Memory/MemoryConsolidationLockManager.swift
import Foundation

/// 文件级乐观锁：管理 `<memoryDir>/.consolidate-lock`。
///
/// 设计对齐 Claude Code `consolidationLock.ts`：
/// - lock 文件的 mtime = lastConsolidatedAt（读取后可判断是否到整合时间）
/// - lock 文件的 body = 持有者 PID（防止其他进程或旧 PID 遗留锁）
/// - `tryAcquire()` 返回 prior mtime（用于失败时 rollback），竞争失败返回 `nil`
/// - `rollback(to:)` 将 mtime 恢复到 priorMtime（0 则删除文件）
/// - `commitConsolidation()` 将 mtime 更新为 now（整合成功后调用）
struct MemoryConsolidationLockManager: Sendable {

    private static let lockFileName = ".consolidate-lock"
    /// 超过此时长认为 PID 已死，即使 PID 仍然存在（PID 复用防护）。
    private static let holderStaleDurationSeconds: TimeInterval = 3600

    let memoryDir: URL

    private var lockFileURL: URL {
        memoryDir.appendingPathComponent(Self.lockFileName)
    }

    // MARK: - Public API

    /// 返回 lock 文件的 mtime（毫秒），等同于 `lastConsolidatedAt`。
    /// 文件不存在时返回 0。
    func readLastConsolidatedAt() async throws -> Double {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: lockFileURL.path)
            guard let mtime = attrs[.modificationDate] as? Date else { return 0 }
            return mtime.timeIntervalSince1970 * 1000
        } catch CocoaError.fileNoSuchFile {
            return 0
        }
        // 其他 I/O 错误向上抛出
    }

    /// 尝试获取锁。
    ///
    /// - 返回 prior mtime（毫秒）：成功获取。调用方在失败时应调用 `rollback(to:)`。
    /// - 返回 `nil`：另一个有效的持有者存在（竞争失败）。
    func tryAcquire() async throws -> Double? {
        let path = lockFileURL.path
        var priorMtime: Double = 0
        var holderPID: Int?

        // 读取现有 lock（ENOENT → 无 prior lock）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mtime = (attrs[.modificationDate] as? Date) {
            priorMtime = mtime.timeIntervalSince1970 * 1000
            if let body = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = Int(body.trimmingCharacters(in: .whitespacesAndNewlines)) {
                holderPID = pid
            }
        }

        // 若 lock 存在且在 stale 期内
        if priorMtime > 0 {
            let ageSeconds = (Date.now.timeIntervalSince1970 * 1000 - priorMtime) / 1000
            if ageSeconds < Self.holderStaleDurationSeconds {
                if let pid = holderPID, isProcessRunning(pid: pid) {
                    return nil  // 有效持有者，竞争失败
                }
                // 持有者已死（PID reuse 防护：超过 stale 阈值也按失效处理）
            }
        }

        // 写入本进程 PID，mtime = now
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: lockFileURL, atomically: true, encoding: .utf8)

        // 验证：双写竞争时最后一个 write 赢，读回 PID 确认是自己
        guard let readBack = try? String(contentsOf: lockFileURL, encoding: .utf8),
              Int(readBack.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(pid) else {
            return nil  // 竞争失败
        }

        return priorMtime
    }

    /// 将 lock 文件 mtime 恢复到 `priorMtime`（毫秒）。
    ///
    /// - `priorMtime == 0`：删除 lock 文件（恢复到无文件状态）。
    /// - 清空 body，避免本进程看起来仍在持有。
    func rollback(to priorMtime: Double) async throws {
        let path = lockFileURL.path
        if priorMtime == 0 {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        // 清空 body
        try "".write(toFile: path, atomically: true, encoding: .utf8)
        // 恢复 mtime
        let t = priorMtime / 1000
        let date = Date(timeIntervalSince1970: t)
        try (FileManager.default as! AnyObject)   // 用 POSIX utimes 更精确，但 FileManager.setAttributes 也可用
        FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: path  // 若失败不抛出，最多延迟下次触发
        )
    }

    /// 将 lock 文件 mtime 更新为 now（整合成功后调用）。
    /// 无论是否先调用 `tryAcquire()`，此方法都可直接使用（例如手动触发时）。
    func commitConsolidation() async throws {
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: lockFileURL, atomically: true, encoding: .utf8)
        // mtime 已被 write(atomically:) 更新为 now，无需额外设置
    }

    // MARK: - Private

    private func isProcessRunning(pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0  // kill(pid, 0) 仅检查存在性，不发送信号
    }
}
```

> **注意**：`rollback(to:)` 使用 `FileManager.setAttributes(_:ofItemAtPath:)` 设置 `modificationDate`。在 macOS 上此方法有效；若需更高精度，可用 `utimes(2)` 系统调用。rollback 失败不应 crash，只是让下一次触发延迟到 minHours 后。

### Step 1-4: 修复编译问题并运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t1 \
  -only-testing:agentGuiTests/MemoryConsolidationLockManagerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 1-5: 提交

```bash
git add agentGui/Services/Memory/MemoryConsolidationLockManager.swift \
        agentGuiTests/MemoryConsolidationLockManagerTests.swift
git commit -m "feat(M-06): add MemoryConsolidationLockManager — file-based mtime lock"
```

---

## Task 2：`MemoryConsolidationScheduleGate`

**文件:**
- Create: `agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift`
- Test: `agentGuiTests/MemoryConsolidationScheduleGateTests.swift`

封装双门槛：时间门（`hoursSince ≥ minHours`）+ 会话数门（SwiftData 查 `Session.updatedAt > lastConsolidatedAt` 且 sessionId ≠ currentSessionId 的条数 ≥ minSessions）。

### Step 2-1: 编写失败测试

```swift
// agentGuiTests/MemoryConsolidationScheduleGateTests.swift
import Testing
import Foundation
import SwiftData
@testable import agentGui

struct MemoryConsolidationScheduleGateTests {

    // MARK: - 时间门关闭

    @Test func timeTooSoonReturnsFalse() async throws {
        let ctx = try makeContext()
        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        // lastConsolidatedAt = now - 20h（不足 24h）
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 20 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(!result.shouldFire)
    }

    // MARK: - 时间门通过但会话数不足

    @Test func timePassedButTooFewSessions() async throws {
        let ctx = try makeContext()
        // 插入 3 个 sessions（需要 5 个）
        for i in 0..<3 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)   // 30 min 前
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(!result.shouldFire)
        #expect(result.sessionCount == 3)
    }

    // MARK: - 双门槛均通过

    @Test func bothGatesPassReturnsTrue() async throws {
        let ctx = try makeContext()
        for i in 0..<6 {
            let s = Session()
            s.sessionId = "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 24,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        #expect(result.shouldFire)
        #expect(result.sessionCount == 6)
    }

    // MARK: - currentSession 被排除

    @Test func currentSessionExcluded() async throws {
        let ctx = try makeContext()
        for i in 0..<5 {
            let s = Session()
            s.sessionId = i == 4 ? "current" : "s\(i)"
            s.title = "Session \(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -1800)
            ctx.insert(s)
        }
        try ctx.save()

        let gate = MemoryConsolidationScheduleGate(
            modelContext: ctx,
            minHours: 1,
            minSessions: 5
        )
        let lastAt = Date.now.timeIntervalSince1970 * 1000 - 2 * 3600 * 1000
        let result = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastAt,
            currentSessionId: "current"
        )
        // 5 sessions 中 current 被排除，只剩 4 个 < minSessions=5
        #expect(!result.shouldFire)
        #expect(result.sessionCount == 4)
    }

    // MARK: - helper

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: config)
        return ModelContext(container)
    }
}
```

### Step 2-2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t2 \
  -only-testing:agentGuiTests/MemoryConsolidationScheduleGateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：编译错误 `cannot find type 'MemoryConsolidationScheduleGate'`

### Step 2-3: 实现 `MemoryConsolidationScheduleGate`

```swift
// agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift
import Foundation
import SwiftData

/// 双门槛检查器：决定是否应该触发记忆整合。
///
/// 门槛顺序（顺序由廉价到昂贵）：
///  1. **时间门**：距 `lastConsolidatedAt` ≥ minHours
///  2. **会话数门**：SwiftData 中 `updatedAt > lastConsolidatedAt` 且非 currentSession 的 Session 计数 ≥ minSessions
///
/// nonisolated struct，内部 async 查 SwiftData，须在 @MainActor 或带 ModelContext 的上下文调用。
struct MemoryConsolidationScheduleGate: Sendable {

    struct CheckResult: Sendable {
        let shouldFire: Bool
        let sessionCount: Int
        let hoursSince: Double
    }

    let minHours: Double
    let minSessions: Int
    let modelContext: ModelContext

    init(modelContext: ModelContext, minHours: Double = 24, minSessions: Int = 5) {
        self.modelContext = modelContext
        self.minHours = minHours
        self.minSessions = minSessions
    }

    /// 检查双门槛，返回结果（含调试信息）。
    @MainActor
    func shouldConsolidate(
        lastConsolidatedAtMs: Double,
        currentSessionId: String
    ) async -> CheckResult {
        let lastAt = Date(timeIntervalSince1970: lastConsolidatedAtMs / 1000)
        let hoursSince = Date.now.timeIntervalSince(lastAt) / 3600

        // --- 时间门 ---
        guard hoursSince >= minHours else {
            return CheckResult(shouldFire: false, sessionCount: 0, hoursSince: hoursSince)
        }

        // --- 会话数门（SwiftData fetch） ---
        let count = sessionCountSince(lastAt, excludingSessionId: currentSessionId)
        let shouldFire = count >= minSessions
        return CheckResult(shouldFire: shouldFire, sessionCount: count, hoursSince: hoursSince)
    }

    // MARK: - Private

    /// 统计 `updatedAt > since` 且 sessionId ≠ excluded 的 Session 数量。
    @MainActor
    private func sessionCountSince(_ since: Date, excludingSessionId excluded: String) -> Int {
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.updatedAt > since && $0.sessionId != excluded }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}
```

### Step 2-4: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t2 \
  -only-testing:agentGuiTests/MemoryConsolidationScheduleGateTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 2-5: 提交

```bash
git add agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift \
        agentGuiTests/MemoryConsolidationScheduleGateTests.swift
git commit -m "feat(M-06): add MemoryConsolidationScheduleGate — dual-gate time+session check"
```

---

## Task 3：`MemoryConsolidationPromptBuilder`

**文件:**
- Create: `agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift`
- Test: `agentGuiTests/MemoryConsolidationPromptBuilderTests.swift`

4 阶段 prompt（Orient → Gather → Consolidate → Prune），对齐 Claude Code `consolidationPrompt.ts`，适配 agentGui 的路径结构和工具约束。

### Step 3-1: 编写失败测试

```swift
// agentGuiTests/MemoryConsolidationPromptBuilderTests.swift
import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationPromptBuilderTests {

    private let builder = MemoryConsolidationPromptBuilder()

    @Test func promptContainsFourPhases() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp/memory"),
            sessionIds: ["aaa", "bbb"],
            sessionCount: 2
        )
        #expect(prompt.contains("Phase 1"))
        #expect(prompt.contains("Phase 2"))
        #expect(prompt.contains("Phase 3"))
        #expect(prompt.contains("Phase 4"))
    }

    @Test func promptContainsMemoryDirPath() {
        let memDir = URL(fileURLWithPath: "/Users/feint/.agentgui/memory")
        let prompt = builder.build(
            memoryDir: memDir,
            sessionIds: ["x"],
            sessionCount: 1
        )
        #expect(prompt.contains(memDir.path))
    }

    @Test func promptListsSessionIds() {
        let ids = ["session-abc", "session-def"]
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: ids,
            sessionCount: ids.count
        )
        for id in ids {
            #expect(prompt.contains(id))
        }
    }

    @Test func promptContainsMEMORYMDConstraint() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: [],
            sessionCount: 0
        )
        #expect(prompt.contains("MEMORY.md"))
        #expect(prompt.contains("200"))   // 行数上限
    }

    @Test func promptContainsToolConstraintNote() {
        let prompt = builder.build(
            memoryDir: URL(fileURLWithPath: "/tmp"),
            sessionIds: [],
            sessionCount: 0
        )
        // 工具约束：只允许读操作，不允许 bash 写入
        #expect(prompt.lowercased().contains("read-only") || prompt.lowercased().contains("只读"))
    }
}
```

### Step 3-2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t3 \
  -only-testing:agentGuiTests/MemoryConsolidationPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 3-3: 实现 `MemoryConsolidationPromptBuilder`

```swift
// agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift
import Foundation

/// 为 consolidation subagent 构建 4 阶段 prompt。
///
/// 对齐 Claude Code `consolidationPrompt.ts`，但：
/// - 不依赖 transcript 目录路径（agentGui 用 SwiftData 存会话，subagent 只读内存目录）
/// - 对 Bash 工具的约束改为文案描述（subagent 本身通过工具白名单控制）
struct MemoryConsolidationPromptBuilder: Sendable {

    private static let maxIndexLines = 200
    private static let entrypointName = "MEMORY.md"

    func build(
        memoryDir: URL,
        sessionIds: [String],
        sessionCount: Int
    ) -> String {
        let memPath = memoryDir.path
        let sessionListText = sessionIds.isEmpty
            ? "（无可用 session ID）"
            : sessionIds.map { "- \($0)" }.joined(separator: "\n")

        return """
        # Dream：记忆整合

        你正在执行一次 dream —— 对记忆文件的反思性整理。\
        将最近多个 session 中学到的内容合并为持久、组织良好的记忆，以便未来 session 快速定向。

        记忆目录：`\(memPath)`

        ---

        ## Phase 1 — Orient（定向）

        - 用文件读取工具列出记忆目录，查看已有文件。
        - 读取 `\(Self.entrypointName)` 对现有索引建立全局印象。
        - 快速浏览各话题文件的 frontmatter，避免创建重复文件。
        - 若目录不存在，直接继续到 Phase 3 创建初始记忆。

        ---

        ## Phase 2 — Gather（采集新信号）

        以下 \(sessionCount) 个 session 在上次整合后发生过活动（排除了当前 session）：

        \(sessionListText)

        采集策略（按优先级）：
        1. 检查已有记忆文件中是否有已过时或矛盾的事实（与当前代码库/环境不符）。
        2. 回忆本次运行前 session 中讨论过、多次出现、或明显需要长期记住的信息。
        3. 不要穷举 session 内容——只专注于你已认为重要的信号。

        > **工具约束（本次运行）**：仅使用文件读取工具（read_file、file_glob、file_search）。
        > 不要执行 Bash 写入命令或修改记忆目录以外的任何文件。

        ---

        ## Phase 3 — Consolidate（整合）

        对每条值得保留的内容，在记忆目录顶层写入或更新对应话题文件。\
        遵循系统 prompt 中 auto-memory 节的文件格式和类型约定。

        重点：
        - 将新信号 **合并** 到已有话题文件，而非创建近似重复。
        - 将相对时间（"昨天"、"上周"）转换为绝对日期，确保日后仍可理解。
        - **删除已被推翻的事实**：若当前调查否定了旧记忆，直接在源文件修正，而不是添加矛盾条目。

        ---

        ## Phase 4 — Prune & Index（修剪索引）

        更新 `\(Self.entrypointName)`，保持 ≤ \(Self.maxIndexLines) 行且 ≤ 25 KB。\
        它是**索引**，不是转储——每行应 ≤ 150 字符：`- [Title](file.md) — 一行摘要`。\
        禁止将记忆内容直接写入索引文件。

        - 删除已过时、错误或已被替代的记忆的指针。
        - 缩短过长的索引行（> 200 字符）：把详细内容移入话题文件。
        - 为新写入的重要记忆添加指针。
        - 解决矛盾：若两个文件描述冲突，修正错误的那个。

        ---

        完成后，返回一段简短摘要：整合了什么、更新了什么、修剪了什么。\
        若记忆已经整洁紧凑，无需改动，也请明确说明。
        """
    }
}
```

### Step 3-4: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t3 \
  -only-testing:agentGuiTests/MemoryConsolidationPromptBuilderTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 3-5: 提交

```bash
git add agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift \
        agentGuiTests/MemoryConsolidationPromptBuilderTests.swift
git commit -m "feat(M-06): add MemoryConsolidationPromptBuilder — 4-phase dream prompt"
```

---

## Task 4：`WorkflowRoleDefinition.consolidationDaemon` + `AppSettings` 配置字段

**文件:**
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`（添加 `.consolidationDaemon` static 属性）
- Modify: `agentGui/Models/AppSettings.swift`（添加 2 个配置字段）
- Test: `agentGuiTests/MemoryConsolidationServiceTests.swift`（Task 5 的测试中间接验证）

### Step 4-1: 添加新的 AppSettings 字段

打开 `agentGui/Models/AppSettings.swift`，在 `/// 启用后台 Agent 调度` 附近添加：

```swift
// MARK: - M-06 Memory Consolidation Daemon

/// 触发整合所需的最小间隔小时数（默认 24h）
var memoryConsolidationMinHours: Double = 24.0

/// 触发整合所需的最小累积 session 数（默认 5）
var memoryConsolidationMinSessions: Int = 5

/// 是否启用后台记忆整合 Daemon（默认开启，依赖 memoryEnabled）
var memoryConsolidationEnabled: Bool = true
```

同时在 `init()` 中添加对应默认值：

```swift
self.memoryConsolidationMinHours = 24.0
self.memoryConsolidationMinSessions = 5
self.memoryConsolidationEnabled = true
```

> **注意**：添加 `@Model` 属性需要 SwiftData Migration。确认系统是否有 `PersistenceSchema.Version` 管理迁移；若有，需新建对应 `MigrationPlan` 版本。若项目使用 `isStoredInMemoryOnly: true` 的测试 schema，无需迁移测试数据库。

### Step 4-2: 添加 `WorkflowRoleDefinition.consolidationDaemon`

在 `WorkflowRoleDefinition.swift` 的 `extension WorkflowRoleDefinition` 中添加：

```swift
// MARK: - M-06 Consolidation Daemon

/// 记忆整合 Daemon 专用角色。
///
/// 工具权限：只允许文件读取（无 Bash，无写 Web）。
/// 程序员通过 `enableTextEditor: true` 赋予写文件能力（写入 memory 话题文件）。
/// `omitMainContext: true`：不注入 CLAUDE.md / git status（整合任务不需要项目上下文）。
static var consolidationDaemon: WorkflowRoleDefinition {
    WorkflowRoleDefinition(
        name: "consolidation_daemon",
        displayName: "Memory Consolidation Daemon",
        description: "后台整合近期 session 的记忆，将多个 session 的知识蒸馏到持久话题文件。",
        systemPrompt: """
        You are a memory consolidation daemon. \
        Your sole purpose is to read recent session activity and organize long-term memory files.

        Rules:
        - Only operate inside the memory directory you are given.
        - Do not modify any files outside the memory directory.
        - Prefer updating existing topic files over creating new ones.
        - Use the file formats and type conventions specified in the user message.
        - When done, output a concise summary of changes.
        """,
        enableTextEditor: true,
        enableBash: false,
        enableWebSearch: false,
        enableWebFetch: false,
        toolGrants: [],
        readableArtifacts: [],
        writableArtifacts: [],
        subscribesTo: [],
        defaultOutputMessageKind: .result,
        primaryOutputArtifactKind: nil,
        maxTurnsPerActivation: 30,
        maxActivations: 1,
        modelPreference: .preferSonnet,
        effort: nil,
        background: false,
        omitMainContext: true,
        initialPrompt: nil,
        criticalReminder: nil,
        color: "purple",
        disallowedToolNames: [],
        isOneShot: false
    )
}
```

> **注意**：查阅 `WorkflowRoleDefinition.init` 签名确认参数名；`modelPreference` 枚举值需对应已有定义（如 `.preferSonnet`、`.inherit` 等）。

### Step 4-3: 构建验证（无测试文件，直接构建）

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m06-t4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning: .*AppSettings|BUILD"
```

预期：`BUILD SUCCEEDED`，无与新字段相关的错误。

### Step 4-4: 提交

```bash
git add agentGui/Models/AppSettings.swift \
        agentGui/Models/WorkflowRoleDefinition.swift
git commit -m "feat(M-06): add AppSettings consolidation config fields and WorkflowRoleDefinition.consolidationDaemon"
```

---

## Task 5：`MemoryConsolidationService` + `MemoryConsolidationCoordinator`

**文件:**
- Create: `agentGui/Services/Memory/MemoryConsolidationService.swift`
- Test: `agentGuiTests/MemoryConsolidationServiceTests.swift`

整合编排类，包含：
- `MemoryConsolidationCoordinator`（actor）保护 `isRunning` flag，防止并发运行两次。
- `MemoryConsolidationService`（struct）：持有所有依赖，构建`buildCallback()` 供 hook 注入。
- 实际的 `run(...)` 静态方法：读 lockManager、检查 scheduleGate、获取锁、运行 subagent、commit / rollback。

### Step 5-1: 编写失败测试

```swift
// agentGuiTests/MemoryConsolidationServiceTests.swift
import Testing
import Foundation
import SwiftData
@testable import agentGui

// MARK: - MemoryConsolidationCoordinatorTests

struct MemoryConsolidationCoordinatorTests {

    @Test func beginReturnsTrueWhenIdle() async {
        let c = MemoryConsolidationCoordinator()
        let result = await c.beginConsolidation()
        #expect(result)
    }

    @Test func beginReturnsFalseWhileRunning() async {
        let c = MemoryConsolidationCoordinator()
        _ = await c.beginConsolidation()
        let second = await c.beginConsolidation()
        #expect(!second)
    }

    @Test func canBeginAgainAfterFinish() async {
        let c = MemoryConsolidationCoordinator()
        _ = await c.beginConsolidation()
        await c.finishConsolidation()
        let again = await c.beginConsolidation()
        #expect(again)
    }
}

// MARK: - MemoryConsolidationServiceTests（双门槛 & lock 验证）

struct MemoryConsolidationServiceTests {

    // MARK: - 时间门未通过 → 不启动 subagent

    @Test func doesNotFireWhenTimeTooSoon() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        var subagentCallCount = 0

        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 1 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - 会话数不足 → 不启动 subagent

    @Test func doesNotFireWhenTooFewSessions() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        for i in 0..<3 {
            let s = Session(); s.sessionId = "s\(i)"; s.title = "S\(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()
        var subagentCallCount = 0

        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - 双门槛通过 → 启动 subagent，传入 sessionIds

    @Test func firesAndPassesSessionIdsWhenBothGatesPass() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        let expectedIds = (0..<6).map { "s\($0)" }
        for id in expectedIds {
            let s = Session(); s.sessionId = id; s.title = id
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()

        var receivedSessionIds: [String] = []
        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { prompt, sessionIds in receivedSessionIds = sessionIds },
            coordinator: MemoryConsolidationCoordinator()
        )

        #expect(receivedSessionIds.count == 6)
        #expect(Set(receivedSessionIds) == Set(expectedIds))
    }

    // MARK: - Coordinator 防重入

    @Test func doesNotFireWhenAlreadyRunning() async throws {
        let dir = tmpMemDir()
        let ctx = try makeContext()
        for i in 0..<6 {
            let s = Session(); s.sessionId = "s\(i)"; s.title = "S\(i)"
            s.updatedAt = Date(timeIntervalSinceNow: -3600)
            ctx.insert(s)
        }
        try ctx.save()

        let coordinator = MemoryConsolidationCoordinator()
        // 预先占用 coordinator
        _ = await coordinator.beginConsolidation()

        var subagentCallCount = 0
        try await MemoryConsolidationService.run(
            lastConsolidatedAtMs: Date.now.timeIntervalSince1970 * 1000 - 25 * 3600 * 1000,
            modelContext: ctx,
            currentSessionId: "current",
            minHours: 24,
            minSessions: 5,
            memoryDir: dir,
            runSubagent: { _, _ in subagentCallCount += 1 },
            coordinator: coordinator
        )

        #expect(subagentCallCount == 0)
    }

    // MARK: - helpers

    private func tmpMemDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m06-svc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Session.self, configurations: config)
        return ModelContext(container)
    }
}
```

### Step 5-2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t5 \
  -only-testing:agentGuiTests/MemoryConsolidationServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：编译错误

### Step 5-3: 实现 `MemoryConsolidationService`

```swift
// agentGui/Services/Memory/MemoryConsolidationService.swift
import Foundation
import SwiftData

// MARK: - MemoryConsolidationCoordinator

/// actor：保护 `isRunning` flag，防止并发二次启动整合。
actor MemoryConsolidationCoordinator {
    private var isRunning = false

    /// 若当前空闲，标记为运行中并返回 `true`；否则返回 `false`。
    func beginConsolidation() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// 标记整合完成（无论成功/失败）。
    func finishConsolidation() {
        isRunning = false
    }
}

// MARK: - MemoryConsolidationService

/// M-06 整合服务：持有依赖，构建供 hook 注入的 callback 闭包。
///
/// 使用方式：在 `AgentLoopHookDependencyFactory.build(state:)` 中创建并调用 `buildCallback()`。
struct MemoryConsolidationService: Sendable {

    let claudeService: ClaudeService
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext

    // MARK: - Public

    /// 构建 consolidation callback 闭包，供 `MemoryConsolidationHook` 使用。
    ///
    /// - 每次 service 实例只创建一个 `MemoryConsolidationCoordinator`，保证同实例不并发。
    func buildCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
        let coordinator = MemoryConsolidationCoordinator()
        let service = claudeService
        let capturedSettings = settings
        let capturedSessionId = sessionId
        let capturedModelContext = modelContext

        return { @Sendable _ in
            guard capturedSettings.memoryEnabled,
                  capturedSettings.memoryConsolidationEnabled else { return }

            do {
                try await MemoryConsolidationService.run(
                    lastConsolidatedAtMs: await MemoryConsolidationLockManager(
                        memoryDir: ConfigDirectoryManager.shared.memoryDir
                    ).readLastConsolidatedAt(),
                    modelContext: capturedModelContext,
                    currentSessionId: capturedSessionId,
                    minHours: capturedSettings.memoryConsolidationMinHours,
                    minSessions: capturedSettings.memoryConsolidationMinSessions,
                    memoryDir: ConfigDirectoryManager.shared.memoryDir,
                    runSubagent: { prompt, sessionIds in
                        // 构建 ToolCall 占位用于 subagent runtime（无父 tool call）
                        let toolCallRecord = ToolCall(id: UUID().uuidString, name: "consolidation_daemon")
                        _ = try? await service.runNamedSubagent(
                            name: WorkflowRoleDefinition.consolidationDaemon.name,
                            task: prompt,
                            toolCallRecord: toolCallRecord,
                            service: service.service!,
                            modelId: capturedSettings.selectedModel,
                            settings: capturedSettings,
                            sessionId: capturedSessionId,
                            modelContext: capturedModelContext
                        )
                    },
                    coordinator: coordinator
                )
            } catch {
                #if DEBUG
                print("[MemoryConsolidationService] error: \(error)")
                #endif
            }
        }
    }

    // MARK: - Internal (visible for testing)

    /// 运行整合流程。
    ///
    /// 通过 `runSubagent` 依赖注入使测试可以 mock subagent 调用。
    /// SwiftData 查询须在 `@MainActor` 语义下执行，`modelContext` 由调用方保证线程正确性。
    @MainActor
    static func run(
        lastConsolidatedAtMs: Double,
        modelContext: ModelContext,
        currentSessionId: String,
        minHours: Double,
        minSessions: Int,
        memoryDir: URL,
        runSubagent: @Sendable (String, [String]) async throws -> Void,
        coordinator: MemoryConsolidationCoordinator
    ) async throws {
        // 1. Coordinator 防重入
        guard await coordinator.beginConsolidation() else { return }
        defer { Task { await coordinator.finishConsolidation() } }

        // 2. 双门槛检查
        let gate = MemoryConsolidationScheduleGate(
            modelContext: modelContext,
            minHours: minHours,
            minSessions: minSessions
        )
        let gateResult = await gate.shouldConsolidate(
            lastConsolidatedAtMs: lastConsolidatedAtMs,
            currentSessionId: currentSessionId
        )
        guard gateResult.shouldFire else { return }

        // 3. 获取 lock 文件锁
        let lockManager = MemoryConsolidationLockManager(memoryDir: memoryDir)
        guard let priorMtime = try await lockManager.tryAcquire() else { return }

        // 4. 获取 sessionIds（重查，确保与 gate 检查的结果一致）
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { [lastMs = lastConsolidatedAtMs, sid = currentSessionId] session in
                session.updatedAt > Date(timeIntervalSince1970: lastMs / 1000)
                    && session.sessionId != sid
            },
            sortBy: [SortDescriptor(\Session.updatedAt, order: .reverse)]
        )
        let sessions = (try? modelContext.fetch(descriptor)) ?? []
        let sessionIds = sessions.map(\.sessionId)

        // 5. 构建 prompt
        let prompt = MemoryConsolidationPromptBuilder().build(
            memoryDir: memoryDir,
            sessionIds: sessionIds,
            sessionCount: sessionIds.count
        )

        // 6. 启动 subagent（失败时 rollback lock）
        do {
            try await runSubagent(prompt, sessionIds)
            try await lockManager.commitConsolidation()
        } catch {
            try? await lockManager.rollback(to: priorMtime)
            throw error
        }
    }
}
```

> **注意**：`FetchDescriptor` 内的 `#Predicate` 对 `Date` 进行比较时需要格外小心。若编译器不支持在闭包捕获中直接使用 `lastConsolidatedAtMs / 1000` 的 `Date`，需先将 `Date` 计算提到捕获变量中。若 SwiftData 不支持 `Date` 构造器在 `#Predicate` 中，改用 `Double` 字段比较或先 fetch 再 filter。

### Step 5-4: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t5 \
  -only-testing:agentGuiTests/MemoryConsolidationServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 5-5: 提交

```bash
git add agentGui/Services/Memory/MemoryConsolidationService.swift \
        agentGuiTests/MemoryConsolidationServiceTests.swift
git commit -m "feat(M-06): add MemoryConsolidationService + MemoryConsolidationCoordinator actor"
```

---

## Task 6：`MemoryConsolidationHook` — AgentLoopHook

**文件:**
- Create: `agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift`
- Test: `agentGuiTests/MemoryConsolidationHookTests.swift`

### Step 6-1: 编写失败测试

```swift
// agentGuiTests/MemoryConsolidationHookTests.swift
import Testing
import Foundation
@testable import agentGui

struct MemoryConsolidationHookTests {

    @Test func supportedStageIsWillFinishRun() {
        let hook = MemoryConsolidationHook(callback: { _ in })
        #expect(hook.supports(.willFinishRun))
        #expect(!hook.supports(.willStartRound))
        #expect(!hook.supports(.prepareRun))
    }

    @Test func performReturnsContinueImmediately() async throws {
        let hook = MemoryConsolidationHook(callback: { _ in })
        let context = AgentLoopHookContext.fixture(executionContext: .mainAgent)
        let result = try await hook.perform(stage: .willFinishRun, context: context)
        #expect(result == .continue)
    }

    @Test func doesNotFireForSubagentContext() async throws {
        var fired = false
        let hook = MemoryConsolidationHook(callback: { _ in fired = true })
        let context = AgentLoopHookContext.fixture(executionContext: .subagent)
        _ = try await hook.perform(stage: .willFinishRun, context: context)
        // 等一个 runloop 让 fire-and-forget task 有机会运行
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fired)
    }

    @Test func firesForMainAgentContext() async throws {
        let expectation = AsyncExpectation()
        let hook = MemoryConsolidationHook(callback: { _ in await expectation.fulfill() })
        let context = AgentLoopHookContext.fixture(executionContext: .mainAgent)
        _ = try await hook.perform(stage: .willFinishRun, context: context)
        await expectation.waitFulfilled(timeout: .seconds(1))
    }
}

// MARK: - helpers (如 AgentLoopHookContext.fixture 已有则复用)
```

> **注意**：`AsyncExpectation` 是项目中其他测试可能已有的测试辅助类型；若无，可改用 `withCheckedContinuation` 等 Swift Testing 原语实现 fulfilled 等待。

### Step 6-2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t6 \
  -only-testing:agentGuiTests/MemoryConsolidationHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

### Step 6-3: 实现 `MemoryConsolidationHook`

对照现有 `MemoryExtractionHook.swift` 一对一实现，模式完全相同：

```swift
// agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift
import Foundation

/// 在 `willFinishRun`（主 agent 完整结束）时，fire-and-forget 启动记忆整合 subagent。
///
/// 设计约束与 `MemoryExtractionHook` 对齐：
/// - `.subagent` 执行上下文不触发（防递归）
/// - `perform` 立即返回 `.continue`，不阻塞主 loop
/// - 实际整合通过注入的 `callback` 闭包执行（由 `AgentLoopHookDependencyFactory` 构建）
/// - order = 92：在 `MemoryExtractionHook`（order = 90）稍后执行，确保 extraction 先完成
struct MemoryConsolidationHook: AgentLoopHook {
    let id = "memory-consolidation"
    let order = 92
    let kind: AgentLoopHookKind = .observer
    let isRequired = false

    let callback: @Sendable (AgentLoopHookContext) async -> Void

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .willFinishRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .willFinishRun else { return .continue }
        guard context.executionContext == .mainAgent else { return .continue }

        let capturedContext = context
        let capturedCallback = callback
        Task.detached(priority: .background) {
            await capturedCallback(capturedContext)
        }

        return .continue
    }
}
```

### Step 6-4: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-t6 \
  -only-testing:agentGuiTests/MemoryConsolidationHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```

预期：所有测试 PASS。

### Step 6-5: 提交

```bash
git add agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift \
        agentGuiTests/MemoryConsolidationHookTests.swift
git commit -m "feat(M-06): add MemoryConsolidationHook — fire-and-forget at willFinishRun"
```

---

## Task 7：集成 Wiring — `AgentLoopBuiltInHookFactory` + `AgentLoopHookDependencyFactory`

**文件:**
- Modify: `agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`
- Test: 构建验证（集成的正确性通过 Task 5 的单元测试已覆盖）

### Step 7-1: 修改 `AgentLoopBuiltInHookFactory`

在 `Dependencies` struct 中添加 consolidation callback 字段（紧接 `extractMemoriesCallback` 声明）：

```swift
// M-06: 后台记忆整合 Daemon callback
let consolidationCallback: @Sendable (AgentLoopHookContext) async -> Void
```

在 `makeHooks(dependencies:state:)` 中注册新 hook（插在 `MemoryExtractionHook` 之后）：

```swift
// M-06: 后台记忆整合
MemoryConsolidationHook(callback: dependencies.consolidationCallback),
```

### Step 7-2: 修改 `AgentLoopHookDependencyFactory`

在 `build(state:)` 方法内 `AgentLoopBuiltInHookFactory.Dependencies(...)` 初始化调用中添加：

```swift
// M-06
consolidationCallback: buildConsolidationCallback(),
```

在 factory 末尾添加私有方法：

```swift
/// 构建记忆整合 callback。
///
/// - 若 `memoryConsolidationEnabled` 为 false，callback 直接返回（guard 在 service 内部处理）。
/// - `runNamedSubagent` 要求 `ClaudeService.service` 已就绪（有 API key）；
///   若未就绪，callback 会在 `MemoryConsolidationService.run` 内的子agentcall 前捕获错误。
private func buildConsolidationCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
    MemoryConsolidationService(
        claudeService: claudeService,
        settings: runtime.settings,
        sessionId: runtime.sessionId,
        modelContext: runtime.modelContext
    ).buildCallback()
}
```

### Step 7-3: 构建验证

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m06-t7 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`

### Step 7-4: 提交

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift \
        agentGui/Services/AgentLoopHookDependencyFactory.swift
git commit -m "feat(M-06): wire MemoryConsolidationHook into AgentLoopBuiltInHookFactory"
```

---

## Task 8（可选）：`ConsolidationProgressState` — UI Task Indicator

**文件:**
- Create: `agentGui/Services/Memory/ConsolidationProgressState.swift`
- 不包含专属测试（UI state，在 `MemoryConsolidationServiceTests` 中验证回调即可）

参考 Claude Code `DreamTaskState`，提供可在 Footer pill / 后台任务列表展示的整合进度信息。

```swift
// agentGui/Services/Memory/ConsolidationProgressState.swift
import Foundation
import Observation

/// M-06 整合进度的 UI 可见状态。
///
/// 供 Footer 或后台任务列表挂入，展示当前 dream phase 和已触碰的文件路径。
/// 生命周期：整合开始时创建，`isCompleted` 变为 `true` 后可安全释放。
@MainActor
@Observable
final class ConsolidationProgressState {

    enum Phase: String {
        case starting     = "starting"
        case updating     = "updating"
        case completed    = "completed"
        case failed       = "failed"
    }

    private(set) var phase: Phase = .starting
    private(set) var sessionCount: Int = 0
    private(set) var filesTouched: [String] = []
    private(set) var isCompleted: Bool = false
    private(set) var errorMessage: String?

    // MARK: - Internal updates (called by MemoryConsolidationService)

    func markUpdating(filePath: String) {
        if !filesTouched.contains(filePath) {
            filesTouched.append(filePath)
        }
        phase = .updating
    }

    func markCompleted() {
        phase = .completed
        isCompleted = true
    }

    func markFailed(error: String) {
        phase = .failed
        errorMessage = error
        isCompleted = true
    }

    func configure(sessionCount: Int) {
        self.sessionCount = sessionCount
    }
}
```

**集成方式（可选，Task 8 结束后）**：
- 在 `MemoryConsolidationService.run(...)` 中接受一个可选的 `ConsolidationProgressState?` 参数。
- 在 subagent 每轮输出时，解析 `AgentMessage` 中的工具调用路径，调用 `state.markUpdating(filePath:)`。
- 成功后调用 `state.markCompleted()`，失败后调用 `state.markFailed(error:)`。

```bash
git add agentGui/Services/Memory/ConsolidationProgressState.swift
git commit -m "feat(M-06): add ConsolidationProgressState for UI task indicator"
```

---

## Task 9：全量测试 + 竣工验证

### Step 9-1: 运行全部 M-06 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m06-final \
  -only-testing:agentGuiTests/MemoryConsolidationLockManagerTests \
  -only-testing:agentGuiTests/MemoryConsolidationScheduleGateTests \
  -only-testing:agentGuiTests/MemoryConsolidationPromptBuilderTests \
  -only-testing:agentGuiTests/MemoryConsolidationCoordinatorTests \
  -only-testing:agentGuiTests/MemoryConsolidationServiceTests \
  -only-testing:agentGuiTests/MemoryConsolidationHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Test Suite"
```

预期：全部 PASS，无 FAIL。

### Step 9-2: Quality Smoke（全量构建+原有测试不回归）

```bash
xcodebuild build \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-m06-smoke \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`，无新 error。

### Step 9-3: 最终提交

```bash
git tag "feat/m06-memory-consolidation-daemon"
```

---

## 附录 A：新增文件清单

| 文件路径 | 类别 |
|---------|------|
| `agentGui/Services/Memory/MemoryConsolidationLockManager.swift` | 新建 |
| `agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift` | 新建 |
| `agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift` | 新建 |
| `agentGui/Services/Memory/MemoryConsolidationService.swift` | 新建（含 Coordinator actor）|
| `agentGui/Services/Memory/ConsolidationProgressState.swift` | 新建（可选 Task 8）|
| `agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift` | 新建 |
| `agentGui/Models/AppSettings.swift` | 修改（+3 字段）|
| `agentGui/Models/WorkflowRoleDefinition.swift` | 修改（+1 static property）|
| `agentGui/Services/AgentLoopBuiltInHookFactory.swift` | 修改（+1 Dependencies 字段 +1 hook 注册）|
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | 修改（+1 方法 +1 init arg）|
| `agentGuiTests/MemoryConsolidationLockManagerTests.swift` | 新建 |
| `agentGuiTests/MemoryConsolidationScheduleGateTests.swift` | 新建 |
| `agentGuiTests/MemoryConsolidationPromptBuilderTests.swift` | 新建 |
| `agentGuiTests/MemoryConsolidationServiceTests.swift` | 新建 |
| `agentGuiTests/MemoryConsolidationHookTests.swift` | 新建 |

---

## 附录 B：与 Claude Code 的关键差异

| 维度 | Claude Code（TypeScript） | agentGui（Swift） |
|------|--------------------------|------------------|
| 会话枚举 | 扫描 `<projectDir>/*.jsonl` 文件 mtime | SwiftData `FetchDescriptor<Session>` 查 `updatedAt` |
| Forked agent | `runForkedAgent`（共享 prompt cache prefix） | `runNamedSubagent`（独立 loop，无 cache sharing） |
| Lock 文件位置 | `<autoMemPath>/.consolidate-lock` | `~/.agentgui/memory/.consolidate-lock` |
| 进度可见性 | `DreamTaskState` + task registry（Ink React） | `ConsolidationProgressState` @Observable（SwiftUI） |
| 特性开关 | GrowthBook feature flag `tengu_onyx_plover` | `AppSettings.memoryConsolidationEnabled` |
| Scan throttle | `SESSION_SCAN_INTERVAL_MS = 10min`（闭包变量） | SwiftData fetch 足够快，无需独立 throttle（coordinator 防重入即可）|
| Bash 约束 | `createAutoMemCanUseTool()` 白名单 | `enableBash: false` in `WorkflowRoleDefinition.consolidationDaemon` |

---

## 附录 C：常见问题排查

**Q: `MemoryConsolidationService.run` 里 `#Predicate` 对 `Date` 报编译错误**  
A: SwiftData `#Predicate` 不支持在谓词内构建 `Date`。改为先在外部计算 `let cutoffDate = Date(timeIntervalSince1970: lastConsolidatedAtMs / 1000)`，再通过 `@Sendable` 捕获：  
```swift
let cutoff = Date(timeIntervalSince1970: lastConsolidatedAtMs / 1000)
let descriptor = FetchDescriptor<Session>(
    predicate: #Predicate { $0.updatedAt > cutoff && $0.sessionId != currentSessionId }
)
```

**Q: `WorkflowRoleDefinition.consolidationDaemon` 的 `modelPreference` 编译错误**  
A: 查看 `SubagentModelPreference` enum 定义，选择对应枚举值（如 `.preferSonnet`、`.sonnet`、`.inherit`）。

**Q: `MemoryConsolidationLockManager.rollback(to:)` 使用 `FileManager.setAttributes` 设置 mtime 无效**  
A: macOS 上 `FileManager.setAttributes([.modificationDate: date])` 一般有效。若遇到问题，改用 POSIX：  
```swift
var times = utimbuf(
    actime: time_t(priorMtime / 1000),
    modtime: time_t(priorMtime / 1000)
)
utime(path, &times)
```

**Q: `ToolCall(id:name:)` 初始化方式不对**  
A: 查阅 `ToolCall.swift` 确认 designated initializer 签名；若无 `id:name:` 便捷初始化器，使用已有的最合适的 static factory 或自行构造 mock `ToolCall`。
