# S-D3 Subagent Memory Bootstrap Injection — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 当 `WorkflowRoleDefinition.memoryScope != nil` 时，在 `runSubagentLoop` 启动子代理前将代理类型专属 MEMORY.md 内容注入到子代理系统提示；同时修复子代理会意外收到全局主代理记忆的现有 bug。

**Architecture:**  
S-D1（`AgentMemoryPathResolver`）和 S-D2（`WorkflowRoleDefinition.memoryScope` / `explore.agent.md memory: project`）已完成。S-D3 在 `runSubagentLoop` 中增加一行 `composeSubagentMemorySection` 调用，将代理专属记忆节拼入 `systemText`，随后在 `AgentLoopHookDependencyFactory` 里添加一个 guard 防止全局记忆泄漏至子代理。不新增任何 SwiftData 模型或独立注入器类。

**Tech Stack:** Swift 6, SwiftUI/macOS, `AgentLoopMemoryBootstrapComposer`（already exists），`AgentMemoryPathResolver`（already exists），`ConfigDirectoryManager`，`AgentLoopHookDependencyFactory`。

---

## 背景：现有基础设施一览

| 已有组件 | 路径 | 职责 |
|---------|------|------|
| `AgentMemoryScope` | `agentGui/Models/AgentMemoryScope.swift` | `user/project/local` 枚举，S-D1 完成 |
| `AgentMemoryPathResolver` | `agentGui/Services/SubagentGovernance/AgentMemoryPathResolver.swift` | 路径解析 + sanitize，S-D1 完成 |
| `AgentLoopMemoryBootstrapComposer` | `agentGui/Services/Memory/AgentLoopMemoryBootstrapComposer.swift` | 读 MEMORY.md → `## Your Memory` 节 |
| `WorkflowRoleDefinition.memoryScope` | `agentGui/Models/WorkflowRoleDefinition.swift` L88 | S-D2 完成 |
| `explore.agent.md memory: project` | `agentGui/Resources/Agents/explore.agent.md` | S-D2 完成 |
| `AgentLoopHookDependencyFactory.loadMemoryBootstrap` | `agentGui/Services/AgentLoopHookDependencyFactory.swift` L74 | 目前无论主/子代理都读全局 `~/.agentgui/memory/` |

**关键缺口：**
1. `runSubagentLoop`（`ClaudeService+Subagent.swift` L118–230）在构建 `system` 前没有读取代理专属记忆目录。
2. `loadMemoryBootstrap` 当 `request.runSource == "subagent"` 时仍读全局 `ConfigDirectoryManager.shared.memoryDir`，导致主代理全局记忆意外注入到所有子代理。

---

## 实现路径设计

```
runSubagentLoop()
  ↓
  ← systemText = definition.systemPrompt (或 fork / override)
  ↓
  [S-D3 NEW] composeSubagentMemorySection(definition, agentguiBaseDir, workspaceRoot)
       ↓ memoryScope == nil  → None
       ↓ memoryScope != nil  → AgentMemoryPathResolver.memoryDir()
                                └→ AgentLoopMemoryBootstrapComposer.compose()
                                     └→ systemPromptSection (String?) 
  ↓
  finalSystemText = systemText + "\n\n" + section  (仅 section 非 nil 时)
  ↓
  makeEphemeralSystemPrompt(finalSystemText)
  ↓
  runCoreAgentLoop()
    ↓
    AgentLoopHookDependencyFactory.build()
      └→ loadMemoryBootstrap()
           [S-D3 FIX] guard runSource != "subagent" else return nil
           → 主代理：读全局 memoryDir（不变）
           → 子代理：返回 nil（全局记忆不注入）
```

---

## Task 1: 添加 `composeSubagentMemorySection` 静态辅助方法

**Goal:** 将记忆节构造逻辑封装为 `nonisolated static func`，便于独立测试，避免 `runSubagentLoop` 的 API-mock 耦合。

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` — 在 `// MARK: - S-A2 One-Shot Trailer` 之前添加新 MARK 和方法

### Step 1: 写失败测试

**Test file:** `agentGuiTests/AgentMemoryBootstrapInjectionTests.swift`（新建）

```swift
import XCTest
@testable import agentGui

final class AgentMemoryBootstrapInjectionTests: XCTestCase {

    // MARK: - 辅助

    private func makeTmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sd3-tests-\(UUID().uuidString)")
    }

    private func makeRole(
        name: String = "explore",
        memoryScope: AgentMemoryScope? = .user
    ) -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: name,
            displayName: "Test",
            systemPrompt: "You are test.",
            memoryScope: memoryScope
        )
    }

    // MARK: - composeSubagentMemorySection 基础行为

    func test_noScope_returnsNil() {
        let tmpDir = makeTmpDir()
        let role = makeRole(memoryScope: nil)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "memoryScope nil 时不应生成 memory 节")
    }

    func test_userScope_emptyMemoryDir_returnsNil() throws {
        let tmpDir = makeTmpDir()
        // 不写 MEMORY.md，但目录会被 compose 创建
        let role = makeRole(memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "MEMORY.md 为空或不存在时不应生成 memory 节")
    }

    func test_userScope_populatedMemory_returnsSection() throws {
        let tmpDir = makeTmpDir()
        // 在 user scope 路径手动写 MEMORY.md
        let memDir = tmpDir.appendingPathComponent("agent-memory/explore")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        let indexURL = memDir.appendingPathComponent("MEMORY.md")
        try "- ClaudeService.swift should not be edited directly".write(
            to: indexURL, atomically: true, encoding: .utf8
        )

        let role = makeRole(name: "explore", memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )

        XCTAssertNotNil(result, "MEMORY.md 有内容时应生成 memory 节")
        XCTAssertTrue(result!.contains("## Your Memory"),
                      "节标题应包含 '## Your Memory'")
        XCTAssertTrue(result!.contains("ClaudeService.swift"),
                      "节内容应包含记忆文本")
    }

    func test_projectScope_usesWorkspaceRoot() throws {
        let tmpDir = makeTmpDir()
        let workspaceRoot = makeTmpDir()
        // project scope 路径：<workspaceRoot>/.agentgui/agent-memory/<name>/
        let memDir = workspaceRoot
            .appendingPathComponent(".agentgui/agent-memory/explore")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        let indexURL = memDir.appendingPathComponent("MEMORY.md")
        try "- Use project scope memory".write(to: indexURL, atomically: true, encoding: .utf8)

        let role = makeRole(name: "explore", memoryScope: .project)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,   // agentguiBaseDir 未含 MEMORY.md
            workspaceRoot: workspaceRoot
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("project scope memory"))
    }

    func test_agentMemoryDirCreated_whenMemoryScopeSet() {
        let tmpDir = makeTmpDir()
        let role = makeRole(name: "explore", memoryScope: .user)
        _ = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        let expectedDir = tmpDir.appendingPathComponent("agent-memory/explore")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expectedDir.path),
            "调用后代理专属目录应已创建（确保 memory_write 工具可写）"
        )
    }

    func test_invalidAgentName_returnsNil() {
        // 名称含 "/" 无法 sanitize，应静默返回 nil
        let tmpDir = makeTmpDir()
        let role = makeRole(name: "foo/bar", memoryScope: .user)
        let result = ClaudeService.composeSubagentMemorySection(
            definition: role,
            agentguiBaseDir: tmpDir,
            workspaceRoot: nil
        )
        XCTAssertNil(result, "非法代理名称应静默返回 nil，不崩溃")
    }
}
```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：`compileSwiftSources` 阶段报错 `error: type 'ClaudeService' has no member 'composeSubagentMemorySection'`。

### Step 3: 实现 `composeSubagentMemorySection`

在 `ClaudeService+Subagent.swift` 的 `// MARK: - S-A2 One-Shot Trailer` 注释**之前**添加：

```swift
// MARK: - S-D3 Subagent Memory Bootstrap Injection

/// 构造子代理专属 memory 引导注入节（对齐 Claude Code `loadAgentMemoryPrompt`）。
///
/// - 当 `definition.memoryScope` 为 nil 时直接返回 nil（不注入）。
/// - 当代理记忆目录不存在时创建目录（`memory_write` 工具需要可写目录），
///   若目录下 MEMORY.md 为空则返回 nil（不注入占位段）。
/// - 调用方负责将非 nil 的返回值以 `"\n\n"` 追加到 systemText。
///
/// `nonisolated static` 便于单元测试中在不模拟 API 的前提下验证注入逻辑。
nonisolated static func composeSubagentMemorySection(
    definition: WorkflowRoleDefinition,
    agentguiBaseDir: URL,
    workspaceRoot: URL?
) -> String? {
    guard let scope = definition.memoryScope else { return nil }

    let resolver = AgentMemoryPathResolver(
        agentguiBaseDir: agentguiBaseDir,
        workspaceRoot: workspaceRoot
    )

    // 安全校验：非法代理名称静默跳过（路径遍历防护）
    guard AgentMemoryPathResolver.sanitize(definition.name) != nil else { return nil }

    let agentMemDir = resolver.memoryDir(agentType: definition.name, scope: scope)

    // 确保目录存在，供 memory_write 工具写入（fire-and-forget）
    try? FileManager.default.createDirectory(
        at: agentMemDir,
        withIntermediateDirectories: true
    )

    let composer = AgentLoopMemoryBootstrapComposer(memoryDir: agentMemDir)
    return composer.compose().systemPromptSection
}
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`，所有 6 个测试通过。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift \
        agentGuiTests/AgentMemoryBootstrapInjectionTests.swift
git commit -m "feat(S-D3): add composeSubagentMemorySection static helper with tests"
```

---

## Task 2: 在 `runSubagentLoop` 中调用注入逻辑

**Goal:** 将 Task 1 的辅助方法接入实际的子代理 loop，在 `makeEphemeralSystemPrompt` 之前将记忆节追加到 `systemText`。

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` — `runSubagentLoop` 函数内，`let system = makeEphemeralSystemPrompt(systemText)` 行附近

### Step 1: 定位注入点

打开 `ClaudeService+Subagent.swift`，找到 `runSubagentLoop` 函数内以下代码块（约 L155–160）：

```swift
        } else {
            let firstTurnContent = ClaudeService.buildSubagentFirstTurnMessage(
                task: task,
                criticalReminder: definition.criticalReminder
            )
            loopMessages = [.init(role: .user, content: .text(firstTurnContent))]
            systemText = definition.systemPrompt
        }
        let system = makeEphemeralSystemPrompt(systemText)
```

### Step 2: 添加记忆注入（无需新增测试，Task 1 已覆盖核心逻辑）

将 `let system = makeEphemeralSystemPrompt(systemText)` 这一行**替换为**：

```swift
        // S-D3: 将代理专属记忆节追加到系统提示。
        // 当 memoryScope == nil 或记忆文件为空时，composeSubagentMemorySection 返回 nil，
        // 系统提示不变，向后兼容。
        let workspaceRootURL: URL? = settings.workingDirectory.isEmpty
            ? nil
            : URL(fileURLWithPath: settings.workingDirectory)
        let memorySectionText = ClaudeService.composeSubagentMemorySection(
            definition: definition,
            agentguiBaseDir: ConfigDirectoryManager.shared.agentGuiDir,
            workspaceRoot: workspaceRootURL
        )
        let finalSystemText: String
        if let section = memorySectionText {
            finalSystemText = systemText + "\n\n" + section
        } else {
            finalSystemText = systemText
        }
        let system = makeEphemeralSystemPrompt(finalSystemText)
```

> **注意：** `systemText` 局部变量在 `if/else if/else` 分支中已赋值，因此上面的代码在 `if/else if/else` 块结束后紧跟即可。不要修改 `systemText` 变量的声明（它声明为 `let`）；使用新的 `finalSystemText` 中间变量。

### Step 3: 验证编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/agentGui-sd3-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`** BUILD SUCCEEDED **`，无 error。

### Step 4: 运行 Task 1 的测试确认未破坏

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task2 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(S-D3): inject agent-specific memory into subagent system prompt in runSubagentLoop"
```

---

## Task 3: 修复全局记忆泄漏（guard subagent in loadMemoryBootstrap）

**Goal:** 防止全局 `~/.agentgui/memory/MEMORY.md`（主代理记忆）注入到子代理的系统提示；子代理的记忆已在 Task 2 通过 `composeSubagentMemorySection` 正确注入。

**Files:**
- Modify: `agentGui/Services/AgentLoopHookDependencyFactory.swift` — `loadMemoryBootstrap` 私有方法（约 L74）

### Step 1: 写测试（验证 subagent 路径返回 nil）

在 `AgentMemoryBootstrapInjectionTests.swift` 末尾追加新测试类：

```swift
// MARK: - loadMemoryBootstrap 子代理守护测试

/// 验证 AgentLoopHookDependencyFactory 的 memoryBootstrapLoader 对子代理返回 nil，
/// 防止全局主代理记忆泄漏到子代理系统提示。
///
/// 测试方式：通过 AgentLoopBuiltInHookFactory.Dependencies 的 memoryBootstrapLoader 闭包
/// 间接验证 loadMemoryBootstrap 的守护逻辑（无法直接调用 private func）。
final class SubagentGlobalMemoryGuardTests: XCTestCase {

    @MainActor
    func test_memoryBootstrapLoader_returnsNil_forSubagentRun() async throws {
        // 准备：创建一个有内容的全局 memory dir
        let tmpBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd3-guard-\(UUID().uuidString)")
        let globalMemDir = tmpBaseDir.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: globalMemDir, withIntermediateDirectories: true)
        try "- global memory entry".write(
            to: globalMemDir.appendingPathComponent("MEMORY.md"),
            atomically: true, encoding: .utf8
        )

        // 构建最小 AgentLoopRunRequest，runSource = "subagent"
        // 使用 @testable import 访问内部类型
        let mockService = MockAnthropicService()
        let request = AgentLoopRunRequest(
            service: mockService,
            modelId: "claude-3-5-haiku-latest",
            tools: [],
            system: nil,
            maxRounds: 5,
            toolExecutionContext: .subagent,
            toolApprovalMode: .bypassApprovals,
            runSource: "subagent",
            runLabel: "test-agent",
            requestedBudgetSeconds: nil
        )

        // 构建最小 AppSettings（memoryEnabled = true，确保不是因为 flag 关闭而跳过）
        let settings = AppSettings.makeForTests(memoryEnabled: true)

        // 构建 AgentLoopRuntime（session = nil，ModelContext = in-memory）
        let modelContext = try ModelContextFactory.makeInMemory()
        let runtime = AgentLoopRuntime(
            settings: settings,
            session: nil,
            sessionId: UUID().uuidString,
            modelContext: modelContext,
            makeRound: { AgentRound(roundIndex: $0) },
            parentMessage: nil,
            streamProjectionTarget: .none,
            toolInterceptor: nil
        )

        // 构建 factory，使用 tmpBaseDir 下的 memory dir（有内容）
        // 注意：AgentLoopHookDependencyFactory 内部用 ConfigDirectoryManager.shared.memoryDir
        // 本测试在 guard 通过之前就返回 nil，所以不需要实际 override memoryDir
        let factory = AgentLoopHookDependencyFactory(
            claudeService: ClaudeService.makeForTests(),
            request: request,
            runtime: runtime,
            bootstrapMessagesSnapshot: []
        )
        let deps = factory.build(state: .init())

        // 验证：子代理 runSource → loader 返回 nil
        let result = try await deps.memoryBootstrapLoader(.init())
        XCTAssertNil(result,
            "runSource='subagent' 时 memoryBootstrapLoader 必须返回 nil，防止全局主代理记忆泄漏")
    }
}
```

> **注意：** 此测试依赖 `ClaudeService.makeForTests()` 和 `AppSettings.makeForTests(memoryEnabled:)` 两个测试工厂方法。检查这些是否已存在（搜索 `makeForTests`）；若不存在，Task 3 Step 1 先在各自文件末端添加：
>
> ```swift
> // MARK: - Test Support
> extension AppSettings {
>     static func makeForTests(memoryEnabled: Bool = true) -> AppSettings {
>         let settings = AppSettings()
>         settings.memoryEnabled = memoryEnabled
>         return settings
>     }
> }
> ```
>
> `ClaudeService.makeForTests()` 应返回一个没有初始化 `service` 的实例，多数现有测试应已有类似 helper；若无则创建：
>
> ```swift
> extension ClaudeService {
>     static func makeForTests() -> ClaudeService { ClaudeService() }
> }
> ```

### Step 2: 运行测试确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests/SubagentGlobalMemoryGuardTests/test_memoryBootstrapLoader_returnsNil_forSubagentRun \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：测试失败，`loader` 返回非 nil（全局记忆内容），断言失败。

### Step 3: 修改 `loadMemoryBootstrap` 添加 guard

打开 `agentGui/Services/AgentLoopHookDependencyFactory.swift`，找到 `loadMemoryBootstrap` 方法（约 L74–82）：

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

在 `guard runtime.settings.memoryEnabled` 之后**添加一行**：

```swift
    private func loadMemoryBootstrap(
        state _: AgentLoopBuiltInHookFactory.State
    ) async throws -> String? {
        guard runtime.settings.memoryEnabled else { return nil }
        // S-D3: 子代理有自己专属的记忆目录（已在 runSubagentLoop 中注入到系统提示）。
        // 全局主代理记忆不应泄漏到子代理，此处统一 guard。
        guard request.runSource != "subagent" else { return nil }
        let composer = AgentLoopMemoryBootstrapComposer(
            memoryDir: ConfigDirectoryManager.shared.memoryDir
        )
        return composer.compose().systemPromptSection
    }
```

### Step 4: 运行测试确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task3 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

预期：`** TEST SUCCEEDED **`，所有测试通过（Task 1 原有 6 个 + Task 3 新增 1 个）。

### Step 5: Commit

```bash
git add agentGui/Services/AgentLoopHookDependencyFactory.swift \
        agentGuiTests/AgentMemoryBootstrapInjectionTests.swift
git commit -m "fix(S-D3): guard global memory bootstrap from subagent runs, prevent main agent memory leak"
```

---

## Task 4: 验证 explore 代理端到端 memory 注入路径

**Goal:** 通过已有测试套件验证 S-D3 不破坏任何现有功能；并确认 `explore` 代理（`memory: project`）的完整注入路径中各环节均正确。

### Step 1: 确认 `AgentDefinitionLoaderOpenAgentTests` 中 `explore` 的 `memoryScope`

在 `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift` 末尾追加：

```swift
    func test_exploreAgent_hasProjectMemoryScope() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        let explore = try XCTUnwrap(docs.first { $0.name == "explore" })
        XCTAssertEqual(explore.memoryScope, .project,
            "explore.agent.md 应声明 memory: project，作为 S-D3 注入的触发条件")
    }
```

### Step 2: 确认 `AgentRuntimeDefinition` 将 `memoryScope` 传播到 `WorkflowRoleDefinition`

在 `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift` 末尾继续追加：

```swift
    func test_exploreAgent_workflowRoleDefinition_hasProjectMemoryScope() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        let explore = try XCTUnwrap(docs.first { $0.name == "explore" })
        let runtime = AgentRuntimeDefinition(document: explore)
        XCTAssertEqual(runtime.workflowRoleDefinition.memoryScope, .project,
            "WorkflowRoleDefinition.memoryScope 应从 AgentDefinitionDocument 传播而来")
    }
```

### Step 3: 运行相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/AgentMemoryBootstrapInjectionTests \
  -only-testing:agentGuiTests/AgentMemoryPathResolverTests \
  -only-testing:agentGuiTests/AgentMemoryScopeTests \
  -only-testing:agentGuiTests/SubagentMemoryScopeToolInjectionTests \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-task4 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case) .* (passed|failed)|** TEST"
```

预期：所有测试通过，无 failed。

### Step 4: 运行全量 Quality Smoke 确保无回归

使用 VS Code task：`Quality Smoke`，或手动运行：

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sd3-smoke \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

预期：`** TEST SUCCEEDED **`。

### Step 5: Commit

```bash
git add agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "test(S-D3): verify explore agent memory scope propagation end-to-end"
```

---

## 验收标准检查单

| # | 验收条件 | 验证方式 |
|---|---------|---------|
| 1 | explore 子代理系统提示中出现 `## Your Memory` 块（当 `~/.agentgui/agent-memory-local/explore/MEMORY.md` 非空时对 project scope） | `test_userScope_populatedMemory_returnsSection` / `test_projectScope_usesWorkspaceRoot` |
| 2 | `memoryScope == nil` 的代理不注入记忆 | `test_noScope_returnsNil` |
| 3 | MEMORY.md 为空时不注入占位段（对齐 `AgentLoopMemoryBootstrapComposer` 现有行为） | `test_userScope_emptyMemoryDir_returnsNil` |
| 4 | 调用后代理专属目录已创建（`memory_write` 工具可写） | `test_agentMemoryDirCreated_whenMemoryScopeSet` |
| 5 | 非法代理名称（含 `/`）静默跳过，不崩溃 | `test_invalidAgentName_returnsNil` |
| 6 | 主代理全局记忆（`~/.agentgui/memory/`）不注入到子代理 | `test_memoryBootstrapLoader_returnsNil_forSubagentRun` |
| 7 | 主代理运行时全局记忆注入行为不变（`loadMemoryBootstrap` 与现有主代理 loop 兼容） | 全量 Quality Smoke 通过 |

---

## 注意事项

### `systemText` 是 `let` 不是 `var`

`runSubagentLoop` 内 `systemText` 在 `if/else if/else` 后赋值，编译器识别为 `let`。S-D3 不修改 `systemText` 声明，而是引入 `finalSystemText` 变量，只修改紧接其后的 `makeEphemeralSystemPrompt` 调用入参。

### `fork` 路径同样受益

当 `forkOverride != nil` 时，`let systemText = fork.parentSystemPromptText ?? definition.systemPrompt`。如果 fork 的父代理本身是 explore 类型并携带 `memoryScope`，那么 `composeSubagentMemorySection` 也会追加对应记忆节。这是正确的行为：fork 复制父上下文后，需要携带自己的记忆积累。

### `ConfigDirectoryManager.shared.agentGuiDir` 是 `~/.agentgui/`

对于 `.user` scope，解析得到 `~/.agentgui/agent-memory/<agentType>/`；对于 `.project` scope，解析得到 `<workspaceRoot>/.agentgui/agent-memory/<agentType>/`。这与 S-D1 中 `AgentMemoryPathResolver` 的路径约定完全一致。

### 目录创建时机

`composeSubagentMemorySection` 在函数内部 fire-and-forget 创建目录（`try?`），即使 MEMORY.md 不存在也会创建目录。这确保子代理在收到系统提示后可立即通过 `memory_write` 工具写入记忆，无需预先创建目录。

### `memoryBootstrapLoader` 内 `loadMemoryBootstrap` 的作用域

`loadMemoryBootstrap` 是 `AgentLoopHookDependencyFactory` 的 `private func`，通过 `buildExtractionCallback` 闭包暴露给 `AgentLoopBuiltInHookFactory.Dependencies`。只需一行 `guard request.runSource != "subagent" else { return nil }`，对主代理 loop（`runSource == "main"` 或其他非 `"subagent"` 值）完全透明。
