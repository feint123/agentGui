# Memory M-05: Memory Bootstrap → 读 MEMORY.md 注入系统提示 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `MemoryBootstrapHook` 从 MEMORY.md 读取内容，通过新增的 `systemPromptAppend` hook result 将内容追加到系统提示，替代当前的 `nil` stub 和旧版 user/assistant 消息对注入方式；同时将系统提示中的 MEMORY.md 索引注入职责从 `buildSystemPrompt()` 迁移到 bootstrap hook。 

**Architecture:** 新增 `AgentLoopHookResult.systemPromptAppend(String)` → `MemoryBootstrapHook` 返回此 result → `applyBootstrap()` 把 append 内容存入 `AgentLoopRunState.bootstrapSystemAppend` → `executeStreamingRound()` 将其追加到 `request.system` 后再发 API。引入 `AgentLoopMemoryBootstrapComposer` 封装"读 MEMORY.md → 格式化 `<memory>` 块"逻辑。

**Tech Stack:** Swift 6, SwiftAnthropic `MessageParameter.System.list([Cache])`

**依赖 Feature：** M-01（deleteRMS，当前 `loadMemoryBootstrap()` 已是 `nil` stub）

---

## 前置阅读（实施前必看）

| 文件 | 目的 |
|------|------|
| `agentGui/Models/AgentLoopHookModels.swift` | `AgentLoopHookResult` 枚举（line 69），`AgentLoopHookDispatchResult`（line 95） |
| `agentGui/Services/AgentLoopHookDispatcher.swift` | 分发逻辑，处理 hook result |
| `agentGui/Services/AgentLoopRoundExecutor.swift` | `applyBootstrap()` 方法（约 line 70），`executeStreamingRound()` 方法（约 line 137） |
| `agentGui/Services/AgentLoopRunner.swift` | `run()` 方法，了解 bootstrap → round 调用顺序 |
| `agentGui/Models/AgentLoopRunState.swift` | 状态携带字段，需添加 `bootstrapSystemAppend` |
| `agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift` | 当前 hook 实现，返回 `.messagePatch` |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | `loadMemoryBootstrap()` stub（返回 nil） |
| `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift` | `buildSystemPrompt()` 当前包含 MEMORY.md 注入（约 line 262-270） |
| `agentGui/Services/Memory/MemoryIndexReader.swift` | `read(from url:) -> ReadResult?` 接口 |
| `agentGui/Utilities/ConfigDirectoryManager.swift` | `memoryIndexURL` 路径 |

---

## Task 1：新增 `AgentLoopHookResult.systemPromptAppend` + 更新 dispatch 结果

**Files:**
- Modify: `agentGui/Models/AgentLoopHookModels.swift`
- Modify: `agentGui/Services/AgentLoopHookDispatcher.swift`

### Step 1: 在 `AgentLoopHookModels.swift` 中更新 `AgentLoopHookResult`

找到 `AgentLoopHookResult`:
```swift
enum AgentLoopHookResult: Equatable {
    case `continue`
    case decision(AgentLoopDecision)
    case messagePatch(AgentLoopMessagePatch)
    case toolCallRecord(ToolCall)
    case failureTrigger(FailureTrigger)
    ...
}
```

在 `case failureTrigger(FailureTrigger)` 之后添加新 case：

```swift
    /// Bootstrap 阶段专用：将 `section` 追加到本次 run 的系统提示末尾。
    /// 不插入消息链。
    case systemPromptAppend(String)
```

同时，在 `static func == ` 中添加对应分支（在 `default:` 之前）：

```swift
case (.systemPromptAppend(let lhs), .systemPromptAppend(let rhs)):
    return lhs == rhs
```

### Step 2: 在 `AgentLoopHookDispatchResult` 中添加 `systemAppend` 字段

找到：
```swift
struct AgentLoopHookDispatchResult {
    var failures: [AgentLoopHookFailure] = []
    var decisions: [AgentLoopDecision] = []
    var abortReason: AgentLoopHookAbortReason?
    var messagePatch: AgentLoopMessagePatch?
    var toolCallRecord: ToolCall?
    var failureTrigger: FailureTrigger?
}
```

在 `var failureTrigger: FailureTrigger?` 之后添加：

```swift
    /// 由 `.systemPromptAppend` hook result 聚合的系统提示附加文本。
    /// 多个 hook 返回 systemPromptAppend 时，内容按 hook order 拼接（\n\n 分隔）。
    var systemAppend: String?
```

### Step 3: 在 `AgentLoopHookDispatcher.swift` 中处理新 case

找到分发 switch 中处理 `.messagePatch` 的代码，在其之后添加对 `.systemPromptAppend` 的处理：

```swift
case .systemPromptAppend(let section):
    if result.systemAppend == nil {
        result.systemAppend = section
    } else {
        result.systemAppend! += "\n\n" + section
    }
```

### Step 4: 编译验证无 error

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "^.*error:" | grep -v "SwiftAnthropic" | head -20
```
Expected: 0 errors（Swift 的 exhaustiveness 检查会要求 switch 覆盖新 case，若有其他 switch 需补全）

> ⚠️ 若出现 "switch must be exhaustive" 错误，在报错文件的 switch 中添加：
> ```swift
> case .systemPromptAppend: break
> ```

### Step 5: Commit

```bash
git add agentGui/Models/AgentLoopHookModels.swift \
        agentGui/Services/AgentLoopHookDispatcher.swift
git commit -m "feat(memory-m05): add AgentLoopHookResult.systemPromptAppend + dispatch support"
```

---

## Task 2：`AgentLoopRunState` — 添加 `bootstrapSystemAppend` 字段

**Files:**
- Modify: `agentGui/Models/AgentLoopRunState.swift`

### Step 1: 添加字段

在 `var budgetRunTracker: BudgetRunTracker` 之后添加：

```swift
    /// Bootstrap 阶段 hook 通过 `.systemPromptAppend` 提交的系统提示追加内容。
    /// 由 `applyBootstrap()` 写入，由 `executeStreamingRound()` 读取并合并到 API 请求。
    var bootstrapSystemAppend: String?
```

在 `init(...)` 中添加默认值参数：

```swift
    init(
        ...
        budgetRunTracker: BudgetRunTracker = BudgetRunTracker(),
        bootstrapSystemAppend: String? = nil    // M-05
    ) {
        ...
        self.budgetRunTracker = budgetRunTracker
        self.bootstrapSystemAppend = bootstrapSystemAppend    // M-05
    }
```

### Step 2: 编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "^.*error:" | grep -v "SwiftAnthropic" | head -10
```
Expected: 0 errors

### Step 3: Commit

```bash
git add agentGui/Models/AgentLoopRunState.swift
git commit -m "feat(memory-m05): add AgentLoopRunState.bootstrapSystemAppend"
```

---

## Task 3：`AgentLoopRoundExecutor` — 连接 bootstrap → systemAppend → streaming round

**Files:**
- Modify: `agentGui/Services/AgentLoopRoundExecutor.swift`

### Step 1: 修改 `applyBootstrap()` — 存储 systemAppend 到 state

找到 `applyBootstrap` 方法：

```swift
func applyBootstrap(
    state: inout AgentLoopRunState,
    messages: inout [MessageParameter.Message]
) async throws {
    guard let bootstrapResult = try? await emitter.dispatch(...),
    let patch = bootstrapResult.messagePatch,
    !patch.insertions.isEmpty else {
        return
    }
    ...
}
```

将方法体修改为同时处理 `messagePatch` 和 `systemAppend`：

```swift
func applyBootstrap(
    state: inout AgentLoopRunState,
    messages: inout [MessageParameter.Message]
) async throws {
    guard let bootstrapResult = try? await emitter.dispatch(
        .prepareRun,
        state: state,
        messages: messages
    ) else { return }

    // 处理 messagePatch（保持向后兼容）
    if let patch = bootstrapResult.messagePatch, !patch.insertions.isEmpty {
        for insertion in patch.insertions.sorted(by: { $0.index < $1.index }) {
            messages.insert(insertion.message, at: min(insertion.index, messages.count))
        }
        if !patch.metadata.isEmpty {
            await emitter.emit(
                .didApplyBootstrap,
                state: state,
                messages: messages,
                overrides: .init(metadata: patch.metadata)
            )
        }
    }

    // 处理 systemPromptAppend（M-05）
    if let appendText = bootstrapResult.systemAppend, !appendText.isEmpty {
        state.bootstrapSystemAppend = appendText
    }
}
```

### Step 2: 修改 `executeStreamingRound()` — 合并 bootstrapSystemAppend 到系统提示

找到 `executeStreamingRound()` 中的：

```swift
let system = request.system
```

替换为：

```swift
// M-05: 若 bootstrap 阶段有系统提示追加内容（如 MEMORY.md），在此合并
let system: MessageParameter.System?
if let appendText = state.bootstrapSystemAppend, !appendText.isEmpty {
    system = Self.appendToSystem(request.system, text: appendText)
} else {
    system = request.system
}
```

然后在 `AgentLoopRoundExecutor` 的 extension 末尾添加私有静态辅助方法：

```swift
// MARK: - System Prompt Extension

/// 将 `text` 作为新 ephemeral block 追加到系统提示列表末尾。
/// - 若 system 为 `.list`，直接追加
/// - 若 system 为 `.text`，包装为 list 再追加
/// - 若 system 为 nil，创建仅含 text 的单块 list
private static func appendToSystem(
    _ system: MessageParameter.System?,
    text: String
) -> MessageParameter.System {
    let appendBlock = MessageParameter.Cache(
        text: text,
        cacheControl: .init(type: .ephemeral)
    )
    switch system {
    case .list(let existing):
        return .list(existing + [appendBlock])
    case .text(let existingText):
        let baseBlock = MessageParameter.Cache(
            text: existingText,
            cacheControl: .init(type: .ephemeral)
        )
        return .list([baseBlock, appendBlock])
    case nil:
        return .list([appendBlock])
    }
}
```

### Step 3: 编译验证

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "^.*error:" | grep -v "SwiftAnthropic" | head -10
```
Expected: 0 errors

### Step 4: Commit

```bash
git add agentGui/Services/AgentLoopRoundExecutor.swift
git commit -m "feat(memory-m05): wire bootstrapSystemAppend through applyBootstrap → executeStreamingRound"
```

---

## Task 4：新建 `AgentLoopMemoryBootstrapComposer`

**Files:**
- Create: `agentGui/Services/Memory/AgentLoopMemoryBootstrapComposer.swift`
- Test (new): `agentGuiTests/MemoryBootstrapSystemPromptInjectionTests.swift`

### Step 1: 新建测试文件（FAIL 预期）

```swift
// agentGuiTests/MemoryBootstrapSystemPromptInjectionTests.swift
import XCTest
@testable import agentGui

final class MemoryBootstrapSystemPromptInjectionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootstrapTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_compose_noMemoryFile_returnsNilSystemSection() {
        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()
        XCTAssertNil(result.systemPromptSection,
                     "MEMORY.md 不存在时 systemPromptSection 应为 nil")
    }

    func test_compose_emptyMemoryFile_returnsNilSystemSection() throws {
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try "   ".write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()
        XCTAssertNil(result.systemPromptSection,
                     "MEMORY.md 为空时 systemPromptSection 应为 nil")
    }

    func test_compose_withMemoryContent_returnsSection() throws {
        let content = "- [User Role](user_role_abc.md) — Senior iOS developer"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertNotNil(result.systemPromptSection, "MEMORY.md 有内容时应返回注入节")
        XCTAssertTrue(result.systemPromptSection!.contains("User Role"),
                      "注入节应包含 MEMORY.md 内容")
    }

    func test_compose_section_containsMemoryTag() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("<memory>"),
                      "注入节应包含 <memory> 标签，对齐 Claude Code 格式")
        XCTAssertTrue(result.systemPromptSection!.contains("</memory>"),
                      "注入节应包含 </memory> 闭合标签")
    }

    func test_compose_section_containsYourMemoryHeader() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("## Your Memory"),
                      "注入节应以 ## Your Memory 开头")
    }

    func test_compose_section_containsDirExistsGuidance() throws {
        let content = "- [Fact](fact.md) — test"
        let indexURL = tempDir.appendingPathComponent("MEMORY.md")
        try content.write(to: indexURL, atomically: true, encoding: .utf8)

        let composer = AgentLoopMemoryBootstrapComposer(memoryDir: tempDir)
        let result = composer.compose()

        XCTAssertTrue(result.systemPromptSection!.contains("memory_write"),
                      "注入节应提示使用 memory_write 工具")
    }
}
```

### Step 2: Run tests to verify FAIL

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```
Expected: compile error `cannot find type 'AgentLoopMemoryBootstrapComposer'`

### Step 3: 创建 `AgentLoopMemoryBootstrapComposer.swift`

```swift
// agentGui/Services/Memory/AgentLoopMemoryBootstrapComposer.swift
import Foundation

/// Memory bootstrap 注入结果。
/// 当 MEMORY.md 存在且非空时，`systemPromptSection` 为系统提示追加节；否则为 nil。
struct AgentLoopMemoryBootstrapComposition: Sendable {
    /// 要追加到系统提示的记忆节文本。nil 表示无记忆可注入（跳过）。
    var systemPromptSection: String?

    /// 无内容时的默认值
    init() { systemPromptSection = nil }
    init(systemPromptSection: String) { self.systemPromptSection = systemPromptSection }
}

/// 读取 `MEMORY.md` 并格式化为系统提示注入节。
///
/// 对齐 Claude Code `loadMemoryPrompt()` / `buildMemoryLines()` 的核心格式：
/// ```markdown
/// ## Your Memory
///
/// The following are your persistent memories from past sessions.
///
/// <memory>
/// [MEMORY.md content]
/// </memory>
///
/// This directory already exists — write to it directly with the memory_write tool.
/// ```
///
/// nonisolated struct，内部调用同步 `MemoryIndexReader`，适合在任意并发上下文调用。
struct AgentLoopMemoryBootstrapComposer: Sendable {

    let memoryDir: URL
    private let reader: MemoryIndexReader

    init(memoryDir: URL, reader: MemoryIndexReader = MemoryIndexReader()) {
        self.memoryDir = memoryDir
        self.reader = reader
    }

    func compose() -> AgentLoopMemoryBootstrapComposition {
        let indexURL = memoryDir.appendingPathComponent("MEMORY.md")
        guard let result = reader.read(from: indexURL), !result.content.isEmpty else {
            return AgentLoopMemoryBootstrapComposition()
        }
        return AgentLoopMemoryBootstrapComposition(
            systemPromptSection: buildSection(content: result.content)
        )
    }

    // MARK: - Private

    private func buildSection(content: String) -> String {
        """
        ## Your Memory

        The following are your persistent memories from past sessions.

        <memory>
        \(content)
        </memory>

        This directory already exists — write to it directly with the memory_write tool.
        """
    }
}
```

### Step 4: Run tests to verify PASS

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All 6 tests PASS

### Step 5: Commit

```bash
git add agentGui/Services/Memory/AgentLoopMemoryBootstrapComposer.swift \
        agentGuiTests/MemoryBootstrapSystemPromptInjectionTests.swift
git commit -m "feat(memory-m05): add AgentLoopMemoryBootstrapComposer — reads MEMORY.md, formats <memory> section"
```

---

## Task 5：更新 `MemoryBootstrapHook` — 返回 `systemPromptAppend` 而非 `messagePatch`

**Files:**
- Modify: `agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift`

### Step 1: 查看当前 hook 类型

当前 `MemoryBootstrapHook.loader` 返回 `AgentLoopMessagePatch?`，hook 返回 `.messagePatch(patch)`。

### Step 2: 修改 loader 类型签名

找到：

```swift
struct MemoryBootstrapHook: AgentLoopHook {
    let id = "memory-bootstrap"
    let order = 20
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    let loader: (AgentLoopHookContext) async throws -> AgentLoopMessagePatch?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .prepareRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .prepareRun else {
            return .continue
        }

        guard let patch = try await loader(context), !patch.insertions.isEmpty else {
            return .continue
        }
        return .messagePatch(patch)
    }
}
```

替换为：

```swift
struct MemoryBootstrapHook: AgentLoopHook {
    let id = "memory-bootstrap"
    let order = 20
    let kind: AgentLoopHookKind = .mutator
    let isRequired = false

    /// Loader 闭包：返回要追加到系统提示的 Memory 节文本，nil 表示跳过注入。
    let loader: (AgentLoopHookContext) async throws -> String?

    func supports(_ stage: AgentLoopHookStage) -> Bool {
        stage == .prepareRun
    }

    func perform(stage: AgentLoopHookStage, context: AgentLoopHookContext) async throws -> AgentLoopHookResult {
        guard stage == .prepareRun else {
            return .continue
        }
        guard let section = try await loader(context), !section.isEmpty else {
            return .continue
        }
        return .systemPromptAppend(section)
    }
}
```

### Step 3: 更新 `AgentLoopBuiltInHookFactory` 中的 hook 构建

找到：
```swift
MemoryBootstrapHook { _ in
    try await dependencies.memoryBootstrapLoader(state)
},
```

由于 `loader` 类型已从 `-> AgentLoopMessagePatch?` 改为 `-> String?`，需要同步更新 `AgentLoopBuiltInHookFactory.Dependencies` 中 `memoryBootstrapLoader` 的类型（见 Task 6）。当前不需修改此行，但编译会失败直到 Task 6 完成。

### Step 4: 编译验证（此阶段预期有类型不匹配错误，Task 6 修复）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:" | grep -v "SwiftAnthropic" | head -10
```
Expected: type mismatch error in `AgentLoopBuiltInHookFactory.swift` — 正常，Task 6 修复。

### Step 5: Commit（暂时带编译错误，Task 6 一并提交）

跳过 commit，与 Task 6 合并提交。

---

## Task 6：更新 `AgentLoopBuiltInHookFactory` 和 `AgentLoopHookDependencyFactory`

**Files:**
- Modify: `agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift`

### Step 1: 更新 `AgentLoopBuiltInHookFactory.Dependencies` 中 `memoryBootstrapLoader` 的类型

找到 `Dependencies` 结构中：
```swift
let memoryBootstrapLoader: @Sendable (AgentLoopBuiltInHookFactory.State) async throws -> AgentLoopMessagePatch?
```

改为：
```swift
/// Bootstrap loader：返回要追加到系统提示的 Memory 节文本，nil 表示跳过注入。
let memoryBootstrapLoader: @Sendable (AgentLoopBuiltInHookFactory.State) async throws -> String?
```

### Step 2: 更新 `AgentLoopHookDependencyFactory.loadMemoryBootstrap()` 实现

找到：

```swift
private func loadMemoryBootstrap(
    state _: AgentLoopBuiltInHookFactory.State
) async throws -> AgentLoopMessagePatch? {
    // M-05: 将在 Feature M-05 中实现从 MEMORY.md 读取并注入
    return nil
}
```

替换为：

```swift
private func loadMemoryBootstrap(
    state _: AgentLoopBuiltInHookFactory.State
) async throws -> String? {
    guard runtime.settings.memoryEnabled else { return nil }
    let composer = AgentLoopMemoryBootstrapComposer(
        memoryDir: ConfigDirectoryManager.shared.memoryDir
    )
    return composer.compose().systemPromptSection
}
```

### Step 3: 编译验证无 error

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "^.*error:" | grep -v "SwiftAnthropic" | head -10
```
Expected: 0 errors

### Step 4: Commit（Task 5 + Task 6 一并）

```bash
git add agentGui/Services/AgentLoopHooks/MemoryBootstrapHook.swift \
        agentGui/Services/AgentLoopBuiltInHookFactory.swift \
        agentGui/Services/AgentLoopHookDependencyFactory.swift
git commit -m "feat(memory-m05): update MemoryBootstrapHook → systemPromptAppend; implement loadMemoryBootstrap via AgentLoopMemoryBootstrapComposer"
```

---

## Task 7：从 `buildSystemPrompt()` 移除 MEMORY.md 索引注入

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Prompting.swift`

### Step 1: 定位 MEMORY.md 注入代码（约 line 260-270）

找到：
```swift
// MEMORY.md 索引（同步读取，文件 ≤25KB，耗时可忽略）
let memoryIndexContent = MemoryIndexReader().read(
    from: ConfigDirectoryManager.shared.memoryIndexURL
)?.content ?? ""
let indexSection = ClaudeService.memoryIndexSection(content: memoryIndexContent)
if !indexSection.isEmpty {
    parts.append(indexSection)
}
```

### Step 2: 删除上述代码块（共 6 行）

这部分功能已由 `MemoryBootstrapHook` 通过 `systemPromptAppend` 在每次 run 前动态注入，不再需要在静态系统提示中包含。

> **注意**：保留 `## Memory System` + `MemoryTypeGuidanceComposer().compose()` 那行 —— 这是行为指导（类型说明、保存方式），不是动态记忆内容，应保留在系统提示中。

### Step 3: 同步更新 `memoryIndexSection` 静态方法（可选保留，测试需要）

`ClaudeService.memoryIndexSection(content:)` 方法本身保留（`MemorySystemPromptInjectionTests` 仍直接调用它），但 `buildSystemPrompt()` 不再调用它。

### Step 4: 更新 `MemorySystemPromptInjectionTests.swift`

找到测试：
```swift
func test_buildSystemPrompt_memoryIndexSectionKey() {
    let section = ClaudeService.memoryIndexSection(content: "- [Test](t.md) — hook")
    XCTAssertTrue(section.contains("## Your Memory Index"))
    XCTAssertTrue(section.contains("- [Test]"))
}
```

此测试验证的是静态辅助方法（已保留），不需要改动。

但需删除或更新原来验证"system prompt 是否包含 MEMORY.md 索引"的测试（如果有）。检查 `MemorySystemPromptInjectionTests.swift` 是否有如下测试：
```swift
func test_buildSystemPrompt_containsMemoryIndexSection() { ... }
```

若存在，删除之（功能已移至 hook，不在 buildSystemPrompt 中验证）。

### Step 5: Run 受影响测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:"
```
Expected: All PASS

### Step 6: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Prompting.swift \
        agentGuiTests/MemorySystemPromptInjectionTests.swift
git commit -m "feat(memory-m05): remove static MEMORY.md injection from buildSystemPrompt — now handled by MemoryBootstrapHook"
```

---

## Task 8：全量验证

### Step 1: 运行所有 Memory 相关测试

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m05-derived \
  -only-testing:agentGuiTests/MemoryBootstrapSystemPromptInjectionTests \
  -only-testing:agentGuiTests/MemorySystemPromptInjectionTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryGuidanceInjectionTests \
  -only-testing:agentGuiTests/MemoryRecallHookTests \
  -only-testing:agentGuiTests/MemoryExtractionHookTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:" | head -40
```
Expected: 所有测试 PASS

### Step 2: 确认 hook dispatch 覆盖（exhaustive switch）

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "warning:.*exhaustive|warning:.*switch" | head -10
```
Expected: 无此类 warning（所有 switch 都已覆盖 `.systemPromptAppend` case）

### Step 3: 运行 AgentLoopRunner 相关测试（如有）

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-m05-derived \
  -only-testing:agentGuiTests/ConversationExecutionRuntimeCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:" | head -20
```

### Step 4: 最终 Commit

```bash
git commit -m "chore(memory-m05): final cleanup — all tests pass" --allow-empty
```

---

## 完成标志检查表

- [ ] `AgentLoopHookResult.systemPromptAppend(String)` case 存在并正确分发
- [ ] `AgentLoopHookDispatchResult` 包含 `systemAppend: String?` 字段
- [ ] `AgentLoopRunState` 包含 `bootstrapSystemAppend: String?` 字段
- [ ] `applyBootstrap()` 将 `bootstrapResult.systemAppend` 写入 `state.bootstrapSystemAppend`
- [ ] `executeStreamingRound()` 将 `state.bootstrapSystemAppend` 追加到系统提示后再发 API
- [ ] `AgentLoopMemoryBootstrapComposer` 文件存在，6 个 `MemoryBootstrapSystemPromptInjectionTests` 通过
- [ ] `MemoryBootstrapHook.loader` 类型为 `-> String?`（原 `-> AgentLoopMessagePatch?`）
- [ ] `loadMemoryBootstrap()` 读取 MEMORY.md 并返回 formatted section（非 nil stub）
- [ ] `buildSystemPrompt()` 不再包含 MEMORY.md 读取逻辑
- [ ] 所有受影响测试 PASS，0 编译 error

---

## 注意事项

1. **向后兼容**：`applyBootstrap()` 仍然处理 `messagePatch`（Task 3 Step 1 中保留了该分支），使其他返回 `messagePatch` 的 hook 不受影响。

2. **memoryEnabled 门控**：`loadMemoryBootstrap()` 在 `settings.memoryEnabled == false` 时返回 nil — 这与 `MemoryBootstrapHook` 的 `isRequired = false` 配合，确保关闭记忆时完全跳过。

3. **系统提示追加顺序**：`appendToSystem()` 将 Memory 块追加在现有系统提示 **末尾**，保证原有行为指导（工具说明、安全准则等）优先级不变。

4. **两次注入问题**：Task 7 中移除了 `buildSystemPrompt()` 对 MEMORY.md 的读取，确保 MEMORY.md 内容只通过 hook 注入一次，不重复。对于子 agent（系统提示为空字符串）path，bootstrap hook 是唯一注入路径，这正是 M-05 的设计意图。

5. **线程安全**：`AgentLoopMemoryBootstrapComposer` 调用同步 `MemoryIndexReader`（文件最大 25KB），在 `@MainActor` 的 `ClaudeService` 上下文中可接受。如担心主线程阻塞，可将 `loadMemoryBootstrap()` 用 `Task.detached` 包装，但当前文件大小限制使阻塞时间可忽略。

6. **所有 switch 需要更新**：Swift 6 的 exhaustive switch 检查会报所有未覆盖 `systemPromptAppend` case 的地方。通常在 `AgentLoopHookDispatcher.swift` 的 hook result 处理 switch 中。Task 1 Step 4 中会看到编译错误提示，逐一修复 `default: break` 即可。
