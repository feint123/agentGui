# M-03: 删除 Consolidation 子系统 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 移除 `MemoryConsolidationService` 及整套 Consolidation 调度基础设施，消除约 400+ 行过度设计代码。Claude Code 没有独立的 consolidation 调度；会话结束的 extraction（M-06/M-10 后续实现）已经足够。

**Architecture:** M-03 完全独立，**不依赖 M-01 或 M-02**，可并行或提前执行。删除 Consolidation 后，`AgentLoopBuiltInHookFactory.Dependencies` 中移除 `consolidationCallback`，`MemoryConsolidationHook` 从 hook pipeline 中移除。`AppSettings` 的三个 consolidation 字段也一并清理。由于 `MemoryConsolidationService.swift` 是唯一读取这些 settings 字段的地方，删除后不会形成悬空引用。

**Tech Stack:** Swift 6.0+, SwiftData

> **前置条件：** 无（M-03 独立执行）
> **后置 Feature：** M-10 Settings 清理中验证无残留

---

## 文件地图（执行前速查）

### 需删除的文件（共 6 个）

```
agentGui/Services/Memory/MemoryConsolidationService.swift        151 行
agentGui/Services/Memory/MemoryConsolidationLockManager.swift    119 行
agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift   87 行
agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift    61 行
agentGui/Services/Memory/ConsolidationProgressState.swift         48 行
agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift    35 行
```

### 需修改的文件（共 3 个）

| 文件 | 修改摘要 |
|------|----------|
| `agentGui/Services/AgentLoopBuiltInHookFactory.swift` | 删除 `consolidationCallback` 字段；从 `makeHooks()` 中移除 `MemoryConsolidationHook` |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | 删除 `buildConsolidationCallback()` 方法；从 `build()` 中移除 `consolidationCallback:` 传参 |
| `agentGui/Models/AppSettings.swift` | 删除三个 consolidation 字段及 `init()` 中的赋值 |

### 需删除的测试（共 5 个）

```
agentGuiTests/MemoryConsolidationServiceTests.swift
agentGuiTests/MemoryConsolidationScheduleGateTests.swift
agentGuiTests/MemoryConsolidationPromptBuilderTests.swift
agentGuiTests/MemoryConsolidationLockManagerTests.swift
agentGuiTests/MemoryConsolidationHookTests.swift
```

---

## Task 1: 删除 Consolidation Service 文件

**Files:**
- Delete: `agentGui/Services/Memory/MemoryConsolidationService.swift`
- Delete: `agentGui/Services/Memory/MemoryConsolidationLockManager.swift`
- Delete: `agentGui/Services/Memory/MemoryConsolidationPromptBuilder.swift`
- Delete: `agentGui/Services/Memory/MemoryConsolidationScheduleGate.swift`
- Delete: `agentGui/Services/Memory/ConsolidationProgressState.swift`
- Delete: `agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift`

**Step 1: 在 Xcode 中删除**

在 Xcode Project Navigator 里多选上述 6 个文件 → 右键 → Delete → **Move to Trash**。

**Step 2: 验证文件消失**

```bash
ls agentGui/Services/Memory/MemoryConsolidation*.swift \
   agentGui/Services/Memory/ConsolidationProgressState.swift \
   agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift 2>&1
# 期望：No such file
```

**Step 3: 尝试构建（预期有编译错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

预期：`MemoryConsolidationHook`、`MemoryConsolidationService` 未定义错误，后续 Task 修复。

**Step 4: Commit（文件删除）**

```bash
git add -A agentGui/Services/Memory/ agentGui/Services/AgentLoopHooks/
git commit -m "chore(M-03): delete Consolidation service files (MemoryConsolidationService, LockManager, etc.)"
```

---

## Task 2: 修复 AgentLoopBuiltInHookFactory.swift

**File:** `agentGui/Services/AgentLoopBuiltInHookFactory.swift`

当前代码（约 line 26 和 55）：
```swift
struct Dependencies {
    // ...
    // M-06: 后台记忆整合 Daemon callback
    let consolidationCallback: @Sendable (AgentLoopHookContext) async -> Void
}

func makeHooks(dependencies: Dependencies, state: State) -> [any AgentLoopHook] {
    [
        // ...
        // M-06: 后台记忆整合
        MemoryConsolidationHook(callback: dependencies.consolidationCallback),
    ]
}
```

**Step 1: 删除 consolidationCallback 字段**

找到 `Dependencies` struct 中：
```swift
// M-06: 后台记忆整合 Daemon callback
let consolidationCallback: @Sendable (AgentLoopHookContext) async -> Void
```
整块删除（包含注释行）。

**Step 2: 从 makeHooks() 中移除 MemoryConsolidationHook**

找到：
```swift
// M-06: 后台记忆整合
MemoryConsolidationHook(callback: dependencies.consolidationCallback),
```
整行删除（包含注释行）。

**Step 3: 修改后的 AgentLoopBuiltInHookFactory.swift 的关键部分应如下**

```swift
struct Dependencies {
    let businessLogSink: BusinessLogSink?
    let memoryBootstrapLoader: (State) async throws -> AgentLoopMessagePatch?
    let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCall
    let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
    // M-03: 会话末记忆自动提取回调
    let extractMemoriesCallback: @Sendable (AgentLoopHookContext) async -> Void
    // M-05: 中段记忆召回服务
    let memoryRecallService: (any MemoryRecallServiceProtocol)?
    // consolidationCallback 已在 M-03 删除
}

func makeHooks(dependencies: Dependencies, state: State) -> [any AgentLoopHook] {
    [
        StreamProjectionHook(),
        RemoteChannelProjectionHook(),
        MemoryBootstrapHook { _ in
            try await dependencies.memoryBootstrapLoader(state)
        },
        ToolAuditHook(
            sink: dependencies.businessLogSink,
            createRecord: { context in
                try await dependencies.createToolCallRecord(context, state)
            },
            updateRecord: { context in
                try await dependencies.updateToolCallRecord(context, state)
            }
        ),
        FailureClassificationHook(),
        BusinessObservabilityHook(sink: dependencies.businessLogSink),
        MemoryExtractionHook(callback: dependencies.extractMemoriesCallback),
        MemoryRecallHook(recallService: dependencies.memoryRecallService),
        // MemoryConsolidationHook 已在 M-03 删除
    ]
}
```

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift
git commit -m "fix(M-03): remove consolidationCallback and MemoryConsolidationHook from AgentLoopBuiltInHookFactory"
```

---

## Task 3: 修复 AgentLoopHookDependencyFactory.swift

**File:** `agentGui/Services/AgentLoopHookDependencyFactory.swift`

当前代码（约 line 31-32）：
```swift
// M-06: 后台记忆整合 Daemon callback
consolidationCallback: buildConsolidationCallback()
```

以及私有方法（约 line 60-68）：
```swift
/// 构建记忆整合 callback（M-06）。
///
/// 若 `memoryConsolidationEnabled` 为 false，callback 直接返回（guard 在 service 内部处理）。
private func buildConsolidationCallback() -> @Sendable (AgentLoopHookContext) async -> Void {
    MemoryConsolidationService(
        claudeService: claudeService,
        settings: runtime.settings,
        sessionId: runtime.sessionId,
        modelContext: runtime.modelContext
    ).buildCallback()
}
```

**Step 1: 从 build() 方法中删除 consolidationCallback 传参**

找到 `AgentLoopBuiltInHookFactory.Dependencies(...)` 初始化调用，删除：
```swift
// M-06
consolidationCallback: buildConsolidationCallback()
```
（包含注释行）。

**Step 2: 删除 buildConsolidationCallback() 私有方法**

找到整个 `private func buildConsolidationCallback()` 方法体（约 10 行），删除。

**Step 3: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopHookDependencyFactory.swift
git commit -m "fix(M-03): remove buildConsolidationCallback from AgentLoopHookDependencyFactory"
```

---

## Task 4: 修复 AppSettings.swift

**File:** `agentGui/Models/AppSettings.swift`

需删除的字段（约 line 124-132）：
```swift
// MARK: - M-06 Memory Consolidation Daemon

/// 触发整合所需的最小间隔小时数（默认 24h）
var memoryConsolidationMinHours: Double = 0.1

/// 触发整合所需的最小累积 session 数（默认 5）
var memoryConsolidationMinSessions: Int = 1

/// 是否启用后台记忆整合 Daemon（默认开启，依赖 memoryEnabled）
var memoryConsolidationEnabled: Bool = true
```

以及 `init()` 中的赋值（约 line 171-173）：
```swift
self.memoryConsolidationMinHours = 0.1
self.memoryConsolidationMinSessions = 1
self.memoryConsolidationEnabled = true
```

**Step 1: 删除三个字段声明**

找到 `// MARK: - M-06 Memory Consolidation Daemon` 注释块，删除整个注释块和三个 `var` 声明（含各自的文档注释，共约 12 行）。

**Step 2: 删除 init() 中的三个赋值**

找到 `init()` 里的三行赋值，整行删除：
```swift
self.memoryConsolidationMinHours = 0.1
self.memoryConsolidationMinSessions = 1
self.memoryConsolidationEnabled = true
```

**Step 3: 确认没有漏掉其他引用**

```bash
grep -n "memoryConsolidation" agentGui/Models/AppSettings.swift
# 期望：空输出
```

**Step 4: 构建检查（此步应无新错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:"
# 期望：空输出（无错误）
```

**Step 5: Commit**

```bash
git add agentGui/Models/AppSettings.swift
git commit -m "fix(M-03): remove memoryConsolidation fields from AppSettings"
```

---

## Task 5: 删除 Consolidation 相关测试

**Files:**
- Delete: `agentGuiTests/MemoryConsolidationServiceTests.swift`
- Delete: `agentGuiTests/MemoryConsolidationScheduleGateTests.swift`
- Delete: `agentGuiTests/MemoryConsolidationPromptBuilderTests.swift`
- Delete: `agentGuiTests/MemoryConsolidationLockManagerTests.swift`
- Delete: `agentGuiTests/MemoryConsolidationHookTests.swift`

**Step 1: 在 Xcode 中删除**

多选上述 5 个测试文件 → Delete → Move to Trash。

**Step 2: 验证文件消失**

```bash
ls agentGuiTests/MemoryConsolidation*.swift 2>&1
# 期望：No such file
```

**Step 3: 运行全量测试（确认无集成测试编译失败）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M03-test \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`

> 注：如果其他测试文件中有间接引用 `MemoryConsolidationScheduleGate` 等类型的 import 或实例化，一并修复。

**Step 4: Commit**

```bash
git add -A agentGuiTests/
git commit -m "test(M-03): delete Consolidation tests (5 files, ~491 lines)"
```

---

## Task 6: 全量 Smoke 验证

**Step 1: 确认无 Consolidation 符号**

```bash
grep -rn "MemoryConsolidation\|ConsolidationProgressState\|consolidationCallback" \
  agentGui/ agentGuiTests/ --include="*.swift" | grep -v "//.*consolidation" | grep -v "\.md"
# 期望：空输出
```

**Step 2: 确认 AppSettings 无 consolidation 字段**

```bash
grep "memoryConsolidation" agentGui/Models/AppSettings.swift
# 期望：空输出
```

**Step 3: 全量编译**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：** BUILD SUCCEEDED **
```

**Step 4: 运行 Hook 相关测试（验证 pipeline 正常）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M03-smoke \
  -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerUsageTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

**Step 5: 最终 Commit**

```bash
git add -A
git commit -m "feat(M-03): complete Consolidation subsystem removal — -400 lines"
```

---

## 完成标志 Checklist

- [ ] `agentGui/Services/Memory/MemoryConsolidation*.swift` 全部消失（4 个文件）
- [ ] `agentGui/Services/Memory/ConsolidationProgressState.swift` 消失
- [ ] `agentGui/Services/AgentLoopHooks/MemoryConsolidationHook.swift` 消失
- [ ] `AgentLoopBuiltInHookFactory.Dependencies` 中无 `consolidationCallback` 字段
- [ ] `makeHooks()` 中无 `MemoryConsolidationHook` 注册
- [ ] `AppSettings` 中无 `memoryConsolidationEnabled`、`memoryConsolidationMinHours`、`memoryConsolidationMinSessions`
- [ ] `grep -r "MemoryConsolidation" agentGui/ --include="*.swift"` 返回空
- [ ] `xcodebuild build` → BUILD SUCCEEDED
- [ ] 全量测试通过

---

## 注意事项

1. **独立执行**：M-03 不依赖 M-01/M-02，可单独作为第一个执行的 Feature。
2. **MemoryConsolidationRule.swift**：该文件出现在 M-02 的删除列表中（`Models/MemoryConsolidationRule.swift`）。若先执行 M-03，需在此计划中一并删除该文件。若先执行 M-02，则此步可跳过。
3. **Settings UI**：经确认，`SettingsMemoryView.swift` 目前未直接引用 `memoryConsolidationEnabled` 等字段（没有 UI 控件绑定到这些设置）。若在 SettingsMemoryView 中发现引用，直接删除对应的 `Toggle` 组件即可。
4. **AgentLoopRoundStreamAssemblerUsageTests**：原测试文件包含部分 RMS 相关测试，M-03 不影响它；若该测试引用了 `MemoryConsolidationHook`，更新调用为无 consolidation 的 hook 列表。
