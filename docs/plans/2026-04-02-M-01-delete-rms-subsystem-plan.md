# M-01: 删除 RMS 子系统 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 彻底移除 RMS（Runtime Memory System）子系统，消除与 Claude Code 设计无关的 ~1,800 行代码，使 memory 子系统简化为单一文件存储通道。

**Architecture:** 只删除，不新增功能。删除 RMS 文件后，相关调用点改为轻量 stub（返回 nil 或占位字符串），留待 M-04 / M-05 填入正式实现。SwiftData `@Model` 字段 `rmsStateJson` 在 schema 变更后通过轻量迁移自动抹除，无需手动迁移代码。

**Tech Stack:** Swift 6.0+, SwiftData, SwiftUI, Xcode 项目文件 (project.pbxproj)

> **前置条件：** 无（M-01 不依赖其他 Feature）
> **后置 Feature：** M-02 依赖 M-01 完成；M-04/M-05/M-06 的正式实现依赖 M-01 完成

---

## 文件地图（执行前速查）

### 需删除的文件（共 16 个）

**Services/**
```
agentGui/Services/RMSExtractor.swift                        245 行
agentGui/Services/RMSInsightGenerator.swift                 490 行
agentGui/Services/RMSInsightStore.swift                     117 行
agentGui/Services/RMSPromptComposer.swift                   114 行
agentGui/Services/RMSSelector.swift                          94 行
agentGui/Services/RMSStateReducer.swift                     187 行
agentGui/Services/RMSRawContentStore.swift                   62 行
agentGui/Services/AgentLoopMemoryBootstrapComposer.swift     67 行
```

**Models/**
```
agentGui/Models/RMSInsight.swift                            269 行
agentGui/Models/RMSInsight+MemoryRecord.swift                46 行
agentGui/Models/RMSMemoryRuntimeContext.swift                 22 行
agentGui/Models/MemorySemanticType.swift                     23 行
agentGui/Models/RMSState.swift                              161 行
agentGui/Models/RMSDelta.swift                               36 行
```

**Views / ViewModels/**
```
agentGui/Views/Memory/RMSCognitionPanel.swift
agentGui/ViewModels/RMSCognitionPanelViewModel.swift
```

### 需修改的文件（共 10 个）

| 文件 | 修改摘要 |
|------|----------|
| `agentGui/Models/SessionTaskState.swift` | 删除 `rmsStateJson` 字段和 `rmsState` computed var |
| `agentGui/Services/SessionTaskStateStore.swift` | 删除 `rmsState(for:)` 方法 |
| `agentGui/Services/AgentLoopHookDependencyFactory.swift` | `loadMemoryBootstrap` 改为 stub 返回 nil；删除 `insightScopes(for:)` |
| `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift` | 删除 `buildUnifiedMemoryBootstrap()` 方法和 `insightScopes()` 方法 |
| `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift` | 删除 `executeGovernedMemoryWrite` / `makeMemoryWriteInsight` / `triggerMemoryIndexRebuild`；两个调用点替换为 stub |
| `agentGui/Services/MemoryExtractionPromptBuilder.swift` | 签名去掉 `existingInsights: [RMSInsight]` 参数 |
| `agentGui/Services/SessionMemoryExtractorService.swift` | 删除 `let existingInsights =...` 行，更新 promptBuilder 调用 |
| `agentGui/Utilities/MemoryFreshnessAnnotator.swift` | 删除 doc comment 中 `RMSPromptComposer` 引用 |
| `agentGui/Services/BuiltInSkills/SkillifySkill.swift` | 删除 RMSInsightStore 注释引用 |
| `agentGui/Views/Settings/SettingsMemoryView.swift` | 删除 "RMS" 相关 UI 文案（仅文案，不删除 memory toggle） |

### 需删除的测试（共 3 个）

```
agentGuiTests/AgentLoopRMSExtractionRemovalTests.swift
agentGuiTests/RMSPromptComposerFreshnessTests.swift
agentGuiTests/RMSInsightSemanticTypeTests.swift
```

### 需修改的测试（共 2 个）

```
agentGuiTests/MemoryExtractionPromptBuilderTests.swift   ← 不再传 existingInsights
agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift  ← 验证 stub 行为
```

---

## Task 1: 删除 RMS Model 文件

**Files:**
- Delete: `agentGui/Models/RMSInsight.swift`
- Delete: `agentGui/Models/RMSInsight+MemoryRecord.swift`
- Delete: `agentGui/Models/RMSState.swift`
- Delete: `agentGui/Models/RMSDelta.swift`
- Delete: `agentGui/Models/RMSMemoryRuntimeContext.swift`
- Delete: `agentGui/Models/MemorySemanticType.swift`

**Step 1: 在 Xcode 中删除**

在 Xcode Project Navigator 里：
1. 按住 Cmd 多选上述 6 个文件
2. 右键 → Delete → **Move to Trash**

这样文件从磁盘和 `project.pbxproj` 同时移除。

**Step 2: 验证文件消失**

```bash
ls agentGui/Models/RMS*.swift agentGui/Models/MemorySemanticType.swift 2>&1
# 期望：No such file
```

**Step 3: 尝试构建（预期有编译错误，记录报错文件名）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | grep -v "^CompileSwift" | head -30
```

预期：出现若干 `use of undeclared type 'RMSInsight'`、`'RMSState'` 等错误，后续 Task 逐一修复。

**Step 4: Commit（文件删除）**

```bash
git add -A agentGui/Models/
git commit -m "chore(M-01): delete RMS model files (RMSInsight, RMSState, RMSDelta, etc.)"
```

---

## Task 2: 删除 RMS Service 文件

**Files:**
- Delete: `agentGui/Services/RMSExtractor.swift`
- Delete: `agentGui/Services/RMSInsightGenerator.swift`
- Delete: `agentGui/Services/RMSInsightStore.swift`
- Delete: `agentGui/Services/RMSPromptComposer.swift`
- Delete: `agentGui/Services/RMSSelector.swift`
- Delete: `agentGui/Services/RMSStateReducer.swift`
- Delete: `agentGui/Services/RMSRawContentStore.swift`
- Delete: `agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`

**Step 1: 在 Xcode 中删除**

同 Task 1，多选上述 8 个文件 → Delete → Move to Trash。

**Step 2: 验证文件消失**

```bash
ls agentGui/Services/RMS*.swift agentGui/Services/AgentLoopMemoryBootstrapComposer.swift 2>&1
# 期望：No such file
```

**Step 3: Commit**

```bash
git add -A agentGui/Services/
git commit -m "chore(M-01): delete RMS service files (RMSInsightStore, RMSExtractor, etc.)"
```

---

## Task 3: 删除 RMS View / ViewModel 文件

**Files:**
- Delete: `agentGui/Views/Memory/RMSCognitionPanel.swift`
- Delete: `agentGui/ViewModels/RMSCognitionPanelViewModel.swift`

**Step 1: 在 Xcode 中删除**

同上，两个文件 → Delete → Move to Trash。

**Step 2: Commit**

```bash
git add -A agentGui/Views/Memory/ agentGui/ViewModels/
git commit -m "chore(M-01): delete RMSCognitionPanel view and viewmodel"
```

---

## Task 4: 修复 SessionTaskState.swift

**File:** `agentGui/Models/SessionTaskState.swift`

`@Model` 中现有 `rmsStateJson` 字段和 computed `rmsState`，删除后 SwiftData 会自动做轻量迁移（旧数据库中该列被忽略）。

**Step 1: 删除 rmsStateJson 字段和 rmsState computed var**

当前代码（line 10, 18, 25, 46-48）：
```swift
// @Model body
var rmsStateJson: String=""

// init 参数
rmsStateJson: String = "",

// init body
self.rmsStateJson = rmsStateJson

// extension
var rmsState: RMSState? {
    guard !rmsStateJson.isEmpty, let data = rmsStateJson.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(RMSState.self, from: data)
}
```

修改后：整个 `rmsStateJson` 字段、init 参数和 `rmsState` 计算属性全部删除。

最终 `SessionTaskState.swift` 应如下（保留其他三个计算属性 plan/todoItems/verification）：

```swift
import Foundation
import SwiftData

@Model
final class SessionTaskState {
    var sessionId: String
    var planJson: String
    var todoJson: String
    var verificationJson: String
    var updatedAt: Date

    init(
        sessionId: String,
        planJson: String = "",
        todoJson: String = "[]",
        verificationJson: String = "",
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.planJson = planJson
        self.todoJson = todoJson
        self.verificationJson = verificationJson
        self.updatedAt = updatedAt
    }
}

extension SessionTaskState {
    var plan: ExecutionPlan? {
        guard !planJson.isEmpty, let data = planJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExecutionPlan.self, from: data)
    }

    var todoItems: [TodoItem] {
        guard let data = todoJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([TodoItem].self, from: data)) ?? []
    }

    var verification: CompletionVerification? {
        guard !verificationJson.isEmpty, let data = verificationJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CompletionVerification.self, from: data)
    }
}
```

**Step 2: 构建检查（仅看新的错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 3: Commit**

```bash
git add agentGui/Models/SessionTaskState.swift
git commit -m "fix(M-01): remove rmsStateJson field from SessionTaskState"
```

---

## Task 5: 修复 SessionTaskStateStore.swift

**File:** `agentGui/Services/SessionTaskStateStore.swift`

**Step 1: 找到并删除 rmsState(for:) 方法**

```bash
grep -n "rmsState" agentGui/Services/SessionTaskStateStore.swift
```

找到类似：
```swift
func rmsState(for sessionId: String) -> RMSState? {
    ...
}
```

整块删除该方法（通常只有几行）。

**Step 2: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 3: Commit**

```bash
git add agentGui/Services/SessionTaskStateStore.swift
git commit -m "fix(M-01): remove rmsState(for:) from SessionTaskStateStore"
```

---

## Task 6: 修复 AgentLoopHookDependencyFactory.swift

**File:** `agentGui/Services/AgentLoopHookDependencyFactory.swift`

当前 `loadMemoryBootstrap()` 里构造 `AgentLoopMemoryBootstrapComposer`（已删除），需替换为 stub 返回 nil。同时删除 `insightScopes(for:)` 辅助方法。

**Step 1: 替换 loadMemoryBootstrap 为 stub**

找到整个 `private func loadMemoryBootstrap(state:) async throws -> AgentLoopMessagePatch?` 方法，替换为：

```swift
private func loadMemoryBootstrap(
    state _: AgentLoopBuiltInHookFactory.State
) async throws -> AgentLoopMessagePatch? {
    // M-05: 将在 Feature M-05 中实现从 MEMORY.md 读取并注入
    return nil
}
```

**Step 2: 删除 insightScopes(for:) 方法**

找到 `private func insightScopes(for state: RMSState?, fallbackSessionID: String) -> [MemoryScope]` 整个方法体（约 25 行），删除。

**Step 3: 删除多余 import（如果出现 SwiftData 未使用 warning）**

检查文件顶部 import，若引入 `import SwiftData` 仍被其他方法使用则保留，否则删除。

**Step 4: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopHookDependencyFactory.swift
git commit -m "fix(M-01): stub out loadMemoryBootstrap in AgentLoopHookDependencyFactory (M-05 pending)"
```

---

## Task 7: 修复 ClaudeService+AgenticLoop.swift

**File:** `agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift`

`buildUnifiedMemoryBootstrap()` 方法（line 244 起，约 85 行）以及其辅助方法 `insightScopes()` 只在本文件内部使用，且不被任何外部调用方调用（test 无引用）。

**Step 1: 删除 buildUnifiedMemoryBootstrap() 方法**

找到 `func buildUnifiedMemoryBootstrap(...)` 整块（包括 `@MainActor` 标注），删除。

**Step 2: 删除 insightScopes() 私有方法**

找到 `private func insightScopes(for state: RMSState?, session: Session?, ...)` 整块，删除。

**Step 3: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 4: Commit**

```bash
git add agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift
git commit -m "fix(M-01): remove buildUnifiedMemoryBootstrap from ClaudeService+AgenticLoop"
```

---

## Task 8: 修复 ClaudeService+ToolDispatch.swift（最大修改）

**File:** `agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift`

现有三个 RMS 方法：
- `executeGovernedMemoryWrite(input:settings:session:modelContext:)` (~当前 line 530，约 60 行)
- `triggerMemoryIndexRebuild(store:)` (~line 594，约 15 行)
- `makeMemoryWriteInsight(id:content:...)` (~line 615，约 25 行)

两个调用点（line 198 和 362），当前调用 `executeGovernedMemoryWrite`。

**Step 1: 删除三个 RMS 方法**

找到并删除：
1. `private func executeGovernedMemoryWrite(...)` 整块
2. `private func triggerMemoryIndexRebuild(store:)` 整块
3. `func makeMemoryWriteInsight(...)` 整块（注意这个是 `func` 非 `private`）

**Step 2: 在两个调用点替换为 stub**

找到 line ~198（在 `case "memory_write":` 的 `executeTool(name:input:settings:session:modelContext:)` 路径）：
```swift
// 修改前
return .detect(await executeGovernedMemoryWrite(input: input, settings: settings, session: session, modelContext: modelContext), toolName: name)

// 修改后
return .detect(await executeFileMemoryWrite(input: input), toolName: name)
```

找到 line ~362（在 `executeTool` 的无 session 重载或提取工具路径）：
```swift
// 修改前  
return .detect(await executeGovernedMemoryWrite(input: input, settings: settings, session: nil, modelContext: modelContext), toolName: name)

// 修改后
return .detect(await executeFileMemoryWrite(input: input), toolName: name)
```

**Step 3: 添加 stub 方法**

在文件末尾添加 stub（放在 `// MARK: - Memory` 下方或文件末尾）：

```swift
// MARK: - Memory Write (Stub)

/// M-04 占位实现。
/// Feature M-04 将替换此方法为直接写 .md 文件的实现。
private func executeFileMemoryWrite(
    input: MessageResponse.Content.Input
) async -> String {
    guard let content = input["content"]?.stringValue, !content.isEmpty else {
        return "Error: missing parameter 'content'"
    }
    // TODO: M-04 将在此实现写 memoryDir/<topic>.md + 重建 MEMORY.md
    return "⚠️ Memory write stub (M-04 not yet implemented). Content received: \(content.prefix(80))..."
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
git add agentGui/Services/ClaudeService/ClaudeService+ToolDispatch.swift
git commit -m "fix(M-01): replace executeGovernedMemoryWrite with stub in ToolDispatch (M-04 pending)"
```

---

## Task 9: 修复 MemoryExtractionPromptBuilder.swift

**File:** `agentGui/Services/MemoryExtractionPromptBuilder.swift`

当前签名：
```swift
static func build(
    newMessageCount: Int,
    existingInsights: [RMSInsight]
) -> String
```

`existingInsights` 段在 M-06 中将被替换为 `MemoryTopicScanner` 扫描结果，M-01 只删除 RMSInsight 依赖。

**Step 1: 修改 build() 方法签名**

```swift
// 修改前
static func build(
    newMessageCount: Int,
    existingInsights: [RMSInsight]
) -> String {
    ...
    // 现有 insights 摘要（防重复写入）
    if !existingInsights.isEmpty {
        lines += [
            "",
            "## Existing memories",
            ...
        ]
        for insight in existingInsights {
            lines.append("- [\(insight.id)] \(insight.summary)")
        }
    }
    ...
}

// 修改后
static func build(
    newMessageCount: Int
) -> String {
    // 删除整个 existingInsights 段落（M-06 将替换为 MemoryTopicScanner 扫描结果）
    ...
}
```

删除 `existingInsights` 参数以及方法体内 `if !existingInsights.isEmpty { ... }` 代码块（约9行）。

**Step 2: 构建检查**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 3: Commit**

```bash
git add agentGui/Services/MemoryExtractionPromptBuilder.swift
git commit -m "fix(M-01): remove existingInsights([RMSInsight]) parameter from MemoryExtractionPromptBuilder"
```

---

## Task 10: 修复 SessionMemoryExtractorService.swift

**File:** `agentGui/Services/SessionMemoryExtractorService.swift`

**Step 1: 删除 existingInsights 加载行，更新 build 调用**

找到（约 line 80-84）：
```swift
// 从 RMSInsightStore 读取现有 insights（防重复写入）
let existingInsights = (try? RMSInsightStore().load(scope: .user)) ?? []

// 构建提取 prompt
let extractionPrompt = MemoryExtractionPromptBuilder.build(
    newMessageCount: messageCount,
    existingInsights: existingInsights
)
```

改为：
```swift
// 构建提取 prompt
let extractionPrompt = MemoryExtractionPromptBuilder.build(
    newMessageCount: messageCount
)
```

**Step 2: 构建检查（此时整体编译错误应大幅减少）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:" | head -20
```

**Step 3: Commit**

```bash
git add agentGui/Services/SessionMemoryExtractorService.swift
git commit -m "fix(M-01): remove RMSInsightStore.load from SessionMemoryExtractorService"
```

---

## Task 11: 修复其他小文件（MemoryFreshnessAnnotator / SkillifySkill / SettingsMemoryView）

**Files:**
- Modify: `agentGui/Utilities/MemoryFreshnessAnnotator.swift`
- Modify: `agentGui/Services/BuiltInSkills/SkillifySkill.swift`
- Modify: `agentGui/Views/Settings/SettingsMemoryView.swift`

**Step 1: MemoryFreshnessAnnotator.swift**

找到以下注释（line ~33）：
```swift
/// 用于 `RMSPromptComposer` 等已有 system-reminder 包裹的调用方。
```
删除这行注释。

**Step 2: SkillifySkill.swift**

```bash
grep -n "RMSInsightStore\|RMS" agentGui/Services/BuiltInSkills/SkillifySkill.swift
```
找到注释中的 `RMSInsightStore` 引用，删除相关注释行。

**Step 3: SettingsMemoryView.swift**

```bash
grep -n "RMS\|rms" agentGui/Views/Settings/SettingsMemoryView.swift
```
删除或替换 "RMS" 相关 UI 文案（如 "RMS Insights" 等文本），保留 `memoryEnabled` toggle。

**Step 4: 构建检查（应无错误）**

```bash
xcodebuild build -project agentGui.xcodeproj -scheme agentGui \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep "error:"
# 期望：空输出（无错误）
```

**Step 5: Commit**

```bash
git add agentGui/Utilities/MemoryFreshnessAnnotator.swift \
        agentGui/Services/BuiltInSkills/SkillifySkill.swift \
        agentGui/Views/Settings/SettingsMemoryView.swift
git commit -m "fix(M-01): cleanup RMS comment references in minor files"
```

---

## Task 12: 删除并修复 RMS 相关测试

**Files:**
- Delete: `agentGuiTests/AgentLoopRMSExtractionRemovalTests.swift`
- Delete: `agentGuiTests/RMSPromptComposerFreshnessTests.swift`
- Delete: `agentGuiTests/RMSInsightSemanticTypeTests.swift`
- Modify: `agentGuiTests/MemoryExtractionPromptBuilderTests.swift`
- Modify: `agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift`

**Step 1: 在 Xcode 中删除 3 个测试文件**

同前，选中三个文件 → Delete → Move to Trash。

**Step 2: 修复 MemoryExtractionPromptBuilderTests.swift**

找到所有 `existingInsights: [RMSInsight]` 参数传入的调用，将签名改为无 `existingInsights` 参数：

```swift
// 修改前
let result = MemoryExtractionPromptBuilder.build(
    newMessageCount: 10,
    existingInsights: [RMSInsight.constraint(id: "x", ...)]
)

// 修改后
let result = MemoryExtractionPromptBuilder.build(newMessageCount: 10)
```

删除测试中 `existingInsights` 相关的 assert（检查 "## Existing memories" 节的测试）。

**Step 3: 修复 ClaudeServiceMemoryExtractionToolsTests.swift**

```bash
grep -n "makeMemoryWriteInsight\|executeGovernedMemoryWrite\|RMSInsight" \
  agentGuiTests/ClaudeServiceMemoryExtractionToolsTests.swift
```

找到调用已删除方法的测试：
- 删除调用 `makeMemoryWriteInsight(...)` 的测试 case
- 若该文件测试了 `memory_write` 工具，更新 assert 为检查 stub 返回的占位字符串（包含 "Memory write stub"）

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M01-derived \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/ClaudeServiceMemoryExtractionToolsTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：`** TEST SUCCEEDED **`

**Step 5: Commit**

```bash
git add -A agentGuiTests/
git commit -m "test(M-01): delete RMS tests; update MemoryExtractionPromptBuilder and MemoryExtractionTools tests"
```

---

## Task 13: 全量 Smoke 验证

**Step 1: 确认无 RMS 符号存在**

```bash
grep -r "RMS\|rms-insights" agentGui/ agentGuiTests/ \
  --include="*.swift" \
  | grep -v "//.*RMS" \
  | grep -v "\.md"
# 期望：空输出（无任何 RMS 运行时符号引用）
```

**Step 2: 全量编译检查**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：** BUILD SUCCEEDED **
```

**Step 3: 运行现有测试套件（memory 相关）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-M01-smoke \
  -only-testing:agentGuiTests/MemoryExtractionPromptBuilderTests \
  -only-testing:agentGuiTests/SessionMemoryExtractorServiceTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

**Step 4: 最终 Commit**

```bash
git add -A
git commit -m "feat(M-01): complete RMS subsystem removal — -1,800 lines"
```

---

## 完成标志 Checklist

- [ ] `agentGui/Models/RMS*.swift` 文件全部消失
- [ ] `agentGui/Models/MemorySemanticType.swift` 消失
- [ ] `agentGui/Services/RMS*.swift` 文件全部消失
- [ ] `agentGui/Services/AgentLoopMemoryBootstrapComposer.swift` 消失
- [ ] `agentGui/Views/Memory/RMSCognitionPanel.swift` 消失
- [ ] `grep -r "RMSInsight\|RMSState\|RMSInsightStore" agentGui/ --include="*.swift"` 返回空
- [ ] `grep "rms-insights.json" agentGui/ -r` 返回空
- [ ] `xcodebuild build` → BUILD SUCCEEDED
- [ ] Memory 相关测试全部通过

---

## 注意事项

1. **SwiftData 迁移**：`SessionTaskState.rmsStateJson` 字段删除后，首次启动 app 时 SwiftData 会自动抹除该列（轻量迁移），不需要 `MigrationStage`。
2. **memory_write stub**：`executeFileMemoryWrite()` 是占位实现，M-04 Feature 将替换为真正的文件操作。
3. **AgentLoopMemoryBootstrapComposer**：bootstrap hook 目前返回 nil（不注入 memory 上下文），M-05 Feature 将替换为读取 MEMORY.md 的实现。
4. **buildUnifiedMemoryBootstrap**：该方法在整个 app 代码中只有定义，无任何外部调用点，可安全删除。
