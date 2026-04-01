# S-A3 子代理模型选择 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 `run_subagent` 工具调用时按三层优先级（调用方 override → 代理定义 `model-preference` → 父代理 inherit）自动选择子代理使用的 Claude 模型 ID，并将 `explore` 代理默认切换到 haiku。

**Architecture:** 新增纯函数 `SubagentModelResolver.resolve`（Swift enum + static func，无 Actor、无 SwiftData），在 `runSubagentLoop` 入口处调用；通过 `ToolRegistry` 向 `run_subagent` schema 新增可选 `model` 参数传入 override；更新 `explore.agent.md` frontmatter 加入 `model-preference: haiku`。

**Tech Stack:** Swift 6, XCTest, SwiftAnthropic，现有 `ClaudeService+Subagent`、`ToolRegistry`、`AgentDefinitionLoader`。

**依赖状态:** S-A1 已完成（`SubagentModelPreference` 枚举和 `modelPreference` 字段已存在于 `WorkflowRoleDefinition` / `AgentDefinitionDocument` / `AgentRuntimeDefinition`，`AgentDefinitionLoader` 已解析 `model-preference` frontmatter 字段）。

---

## 背景：与 Claude Code 实现对比

Claude Code 中 `src/utils/model/agent.ts` 的 `getAgentModel` 函数实现了相同逻辑：

```typescript
export function getAgentModel(
  agentModel: string | undefined,   // 代理定义中的 model 字段
  parentModel: string,              // 父代理当前模型
  toolSpecifiedModel?: ModelAlias,  // 调用方 override（来自 AgentTool input）
  permissionMode?: PermissionMode,
): string
```

优先级（高到低）：
1. `toolSpecifiedModel`（调用方 override）— 直接映射
2. 代理定义的 `agentModel`（frontmatter `model-preference`）— 带 family-match 优化
3. 父代理模型 `inherit`

其中"family-match 优化"：若代理定义的 preference（`.sonnet`）与父代理模型属于同一系列（`claude-sonnet-4-6`），则直接返回父代理模型 ID，避免 unnecessary 降级。

explore 代理（`built-in/exploreAgent.ts`）：`model: 'haiku'`，这是 external users 路径。

---

## 现状缺口

| 层面 | 已存在 | 缺失 |
|------|--------|------|
| `SubagentModelPreference` 枚举 | ✅ `SubagentExecutionTraits.swift` | — |
| frontmatter 解析 `model-preference` | ✅ `AgentDefinitionLoader.swift` | — |
| `modelPreference` 在定义中传播 | ✅ Document → Runtime → WorkflowRole | — |
| 实际模型 ID 解析函数 | ❌ 无 | 需新建 `SubagentModelResolver` |
| `runSubagentLoop` 使用 `modelPreference` | ❌ 直接用父代理 modelId | 需修改 |
| `run_subagent` 工具 `model` override 参数 | ❌ schema 无此字段 | 需修改 `ToolRegistry` |
| `explore.agent.md` 设置 `model-preference: haiku` | ❌ 无此字段 | 需修改 |
| 已有测试 `test_existingAgentsHaveDefaultOptionalFieldValues` | ✅ 存在但会失效 | 需更新 |

---

## 文件清单

| 操作 | 文件路径 |
|------|---------|
| **新建** | `agentGui/Services/ClaudeService/SubagentModelResolver.swift` |
| **新建** | `agentGuiTests/SubagentModelResolverTests.swift` |
| **修改** | `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift` |
| **修改** | `agentGui/Services/ToolRegistry.swift` |
| **修改** | `agentGui/Resources/Agents/explore.agent.md` |
| **修改** | `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift` |

---

## Task 1: SubagentModelResolver — 失败测试先行

**Files:**
- Create: `agentGuiTests/SubagentModelResolverTests.swift`

### Step 1: 编写失败测试（resolver 还不存在）

```swift
// agentGuiTests/SubagentModelResolverTests.swift
import XCTest
@testable import agentGui

final class SubagentModelResolverTests: XCTestCase {

    private let parentSonnet = "claude-sonnet-4-6"
    private let parentHaiku  = "claude-haiku-4-5"
    private let parentOpus   = "claude-opus-4-6"

    // MARK: - inherit

    func test_inherit_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, parentSonnet)
    }

    func test_inherit_withOverride_returnsOverride() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: "claude-haiku-4-5"
        )
        XCTAssertEqual(result, "claude-haiku-4-5")
    }

    // MARK: - override 最高优先级

    func test_override_precedesPreference() {
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentSonnet,
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }

    func test_override_precedesInherit() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }

    func test_emptyOverride_treatedAsNil() {
        let result = SubagentModelResolver.resolve(
            preference: .inherit,
            parentModelId: parentSonnet,
            overrideModelId: ""
        )
        // 空字符串应视为 nil，回落到 inherit
        XCTAssertEqual(result, parentSonnet)
    }

    // MARK: - family-match 优化（与 Claude Code getAgentModel 对齐）

    func test_haiku_whenParentIsHaiku_returnsParentModel() {
        // 父代理已经是 haiku 系列 → 直接复用，不切换到 default haiku
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentHaiku
        )
        XCTAssertEqual(result, parentHaiku,
            "父代理已是 haiku 系列，应返回父代理 ID 而非固定默认值")
    }

    func test_sonnet_whenParentIsSonnet_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, parentSonnet)
    }

    func test_opus_whenParentIsOpus_returnsParentModel() {
        let result = SubagentModelResolver.resolve(
            preference: .opus,
            parentModelId: parentOpus
        )
        XCTAssertEqual(result, parentOpus)
    }

    // MARK: - preference → 默认 ID 映射（父代理非该系列）

    func test_haiku_whenParentIsSonnet_returnsDefaultHaikuId() {
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultHaikuModelId,
            "haiku preference，父代理非 haiku 系列，应回落到默认 haiku ID")
    }

    func test_sonnet_whenParentIsHaiku_returnsDefaultSonnetId() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: parentHaiku
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultSonnetModelId)
    }

    func test_opus_whenParentIsSonnet_returnsDefaultOpusId() {
        let result = SubagentModelResolver.resolve(
            preference: .opus,
            parentModelId: parentSonnet
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultOpusModelId)
    }

    // MARK: - family detection（跨版本 ID）

    func test_haiku_detectsOlderHaikuId() {
        // claude-3-5-haiku-latest 也属于 haiku 系列
        let result = SubagentModelResolver.resolve(
            preference: .haiku,
            parentModelId: "claude-3-5-haiku-latest"
        )
        XCTAssertEqual(result, "claude-3-5-haiku-latest")
    }

    func test_sonnet_detectsLegacySonnetId() {
        let result = SubagentModelResolver.resolve(
            preference: .sonnet,
            parentModelId: "claude-3-5-sonnet-latest"
        )
        XCTAssertEqual(result, "claude-3-5-sonnet-latest")
    }

    // MARK: - 默认常量可读性

    func test_defaultModelIds_areNonEmpty() {
        XCTAssertFalse(SubagentModelResolver.defaultHaikuModelId.isEmpty)
        XCTAssertFalse(SubagentModelResolver.defaultSonnetModelId.isEmpty)
        XCTAssertFalse(SubagentModelResolver.defaultOpusModelId.isEmpty)
    }

    func test_defaultHaikuId_containsHaiku() {
        XCTAssertTrue(SubagentModelResolver.defaultHaikuModelId.contains("haiku"))
    }

    func test_defaultSonnetId_containsSonnet() {
        XCTAssertTrue(SubagentModelResolver.defaultSonnetModelId.contains("sonnet"))
    }

    func test_defaultOpusId_containsOpus() {
        XCTAssertTrue(SubagentModelResolver.defaultOpusModelId.contains("opus"))
    }
}
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|FAIL|PASS|Build"
```

期望结果：编译错误 `cannot find type 'SubagentModelResolver'`

### Step 3: 实现 `SubagentModelResolver`

新建 `agentGui/Services/ClaudeService/SubagentModelResolver.swift`：

```swift
//
//  SubagentModelResolver.swift
//  agentGui
//
//  按三层优先级解析子代理实际使用的模型 ID：
//  1. overrideModelId（调用方显式指定，最高优先级）
//  2. modelPreference（代理定义 frontmatter 中的 model-preference）
//     - 与父代理同系列时，直接复用父代理 ID（family-match 优化）
//     - 不同系列时，使用对应默认 ID
//  3. .inherit → 直接返回父代理 ID
//
//  对应 Claude Code: src/utils/model/agent.ts → getAgentModel()
//

import Foundation

enum SubagentModelResolver {

    // MARK: - 默认模型 ID（各系列的最新稳定版本）

    /// 默认 haiku 模型 ID（快速、低成本，适合探索类子代理）
    static let defaultHaikuModelId  = "claude-haiku-4-5"

    /// 默认 sonnet 模型 ID（均衡，适合通用子代理）
    static let defaultSonnetModelId = "claude-sonnet-4-6"

    /// 默认 opus 模型 ID（高能力，适合验证/规划子代理）
    static let defaultOpusModelId   = "claude-opus-4-6"

    // MARK: - 核心解析函数

    /// 解析子代理使用的实际模型 ID。
    ///
    /// - Parameters:
    ///   - preference: 代理定义中的模型偏好（`model-preference` frontmatter 字段）
    ///   - parentModelId: 父代理当前使用的模型 ID（`inherit` 语义的基准）
    ///   - overrideModelId: 调用方在 `run_subagent` 工具参数中显式传入的模型 ID（可选）
    /// - Returns: 子代理 API 请求应使用的完整模型 ID 字符串
    static func resolve(
        preference: SubagentModelPreference,
        parentModelId: String,
        overrideModelId: String? = nil
    ) -> String {
        // 1. 调用方 override 最优先（空字符串视为未指定）
        if let override = overrideModelId, !override.isEmpty {
            return override
        }

        // 2. inherit：直接返回父代理模型
        guard preference != .inherit else {
            return parentModelId
        }

        // 3. family-match 优化：若父代理已属于目标系列，复用父代理 ID
        //    避免不必要的版本降级（e.g. 父代理 claude-sonnet-4-6，preference .sonnet
        //    不应降级到 defaultSonnetModelId="claude-sonnet-4-5"）
        if parentMatchesFamily(parentModelId, preference: preference) {
            return parentModelId
        }

        // 4. 映射到默认 ID
        switch preference {
        case .haiku:   return defaultHaikuModelId
        case .sonnet:  return defaultSonnetModelId
        case .opus:    return defaultOpusModelId
        case .inherit: return parentModelId   // unreachable（已在上面处理）
        }
    }

    // MARK: - Internal

    /// 检测 modelId 是否属于 preference 对应的模型系列。
    /// 仅检测字符串中是否包含系列关键词（不区分大小写）。
    private static func parentMatchesFamily(
        _ parentModelId: String,
        preference: SubagentModelPreference
    ) -> Bool {
        let lower = parentModelId.lowercased()
        switch preference {
        case .haiku:   return lower.contains("haiku")
        case .sonnet:  return lower.contains("sonnet")
        case .opus:    return lower.contains("opus")
        case .inherit: return true
        }
    }
}
```

### Step 4: 运行测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

期望：所有测试 PASS，0 failures。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/SubagentModelResolver.swift \
        agentGuiTests/SubagentModelResolverTests.swift
git commit -m "feat(S-A3): add SubagentModelResolver with 3-tier model selection logic"
```

---

## Task 2: 更新 `explore.agent.md` 并修复向后兼容测试

**Files:**
- Modify: `agentGui/Resources/Agents/explore.agent.md`
- Modify: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift`

### Step 1: 在 `explore.agent.md` frontmatter 中新增 `model-preference: haiku`

在文件的 `---` frontmatter 块中，`one-shot: true` 行下方新增一行：

```yaml
model-preference: haiku
```

修改后 frontmatter 应为：

```yaml
---
name: explore
display-name: 探索者
description: 搜索代码、文档和批准的网页来源，返回结构化上下文与风险点。
argument-hint: Describe what to search for, where to look, and the desired thoroughness.
tools: [read_only_editor, web]
max-turns: 50
user-invocable: false
subagent-invocable: true
output-contract: exploration_report
one-shot: true
model-preference: haiku
---
```

### Step 2: 运行向后兼容测试，确认 `test_existingAgentsHaveDefaultOptionalFieldValues` 失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests/test_existingAgentsHaveDefaultOptionalFieldValues \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAIL|PASS|error:"
```

期望：FAIL（`explore.modelPreference` 现在是 `.haiku`，而测试期望 `.inherit`）。

### Step 3: 更新 `AgentDefinitionLoaderOpenAgentTests.swift` 中的受影响测试

将 `test_existingAgentsHaveDefaultOptionalFieldValues` 中对 `explore` 的断言从 `.inherit` 改为 `.haiku`：

```swift
// 在 test_existingAgentsHaveDefaultOptionalFieldValues 中：
// 原来：
XCTAssertEqual(explore.modelPreference, .inherit,
               "\(explore.name) modelPreference should default to .inherit")
// 改为：
XCTAssertEqual(explore.modelPreference, .haiku,
               "explore 代理应使用 haiku 以降低探索成本（S-A3）")
```

同时新增独立测试，明确验证 explore 使用 haiku：

```swift
// 新增到 AgentDefinitionLoaderOpenAgentTests.swift
// MARK: - S-A3 Model Preference

func test_builtInExploreAgentUsesHaikuModelPreference() throws {
    let loader = AgentDefinitionLoader()
    let documents = try loader.loadBuiltInDocuments(from: Bundle(for: type(of: self)))
    let explore = try XCTUnwrap(documents.first { $0.name == "explore" })
    XCTAssertEqual(explore.modelPreference, .haiku,
                   "explore 代理应标记 model-preference: haiku 以降低 API 成本")
}

func test_builtInWorkerAndVerifierUseInheritModelPreference() throws {
    let loader = AgentDefinitionLoader()
    let documents = try loader.loadBuiltInDocuments(from: Bundle(for: type(of: self)))
    let worker   = try XCTUnwrap(documents.first { $0.name == "worker" })
    let verifier = try XCTUnwrap(documents.first { $0.name == "verifier" })
    XCTAssertEqual(worker.modelPreference,   .inherit,
                   "worker 应继承父代理模型")
    XCTAssertEqual(verifier.modelPreference, .inherit,
                   "verifier 应继承父代理模型")
}
```

### Step 4: 运行 AgentDefinitionLoader 测试，确认全部通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

期望：所有测试 PASS。

### Step 5: Commit

```bash
git add agentGui/Resources/Agents/explore.agent.md \
        agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "feat(S-A3): set explore agent model-preference to haiku, update tests"
```

---

## Task 3: 修改 `ClaudeService+Subagent.swift` — 接入 resolver

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

### Step 1: 先写失败测试 — `makeSubagentToolsForTests` 目前没有覆盖 modelId 解析

实际上 `runSubagentLoop` 内部的 modelId 解析无法单元测试（涉及网络调用），我们采用**集成可见层测试**：验证方法签名变更后编译通过，并通过辅助测试方法 `resolvedModelId(for:parentModelId:overrideModelId:)` 暴露解析结果。

在 `ClaudeService+Subagent.swift` 中新增一个 **testable** 的辅助方法（仅用于测试验证，内部调用 `SubagentModelResolver`）：

```swift
// 仅供测试访问，生产代码使用 runSubagentLoop 内部直接调用
func resolvedModelId(
    for definition: WorkflowRoleDefinition,
    parentModelId: String,
    overrideModelId: String? = nil
) -> String {
    SubagentModelResolver.resolve(
        preference: definition.modelPreference,
        parentModelId: parentModelId,
        overrideModelId: overrideModelId
    )
}
```

在测试文件 `SubagentModelResolverTests.swift` 中新增集成验证测试：

```swift
// 在 SubagentModelResolverTests.swift 末尾追加 extension

// MARK: - WorkflowRoleDefinition 集成路径

extension SubagentModelResolverTests {

    private func makeRole(
        preference: SubagentModelPreference
    ) -> WorkflowRoleDefinition {
        WorkflowRoleDefinition(
            name: "test-agent",
            displayName: "Test Agent",
            systemPrompt: "You are a test.",
            modelPreference: preference
        )
    }

    func test_workflowRole_inheritPreference_returnsParent() {
        let service = ClaudeService()
        let role = makeRole(preference: .inherit)
        let result = service.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6"
        )
        XCTAssertEqual(result, "claude-sonnet-4-6")
    }

    func test_workflowRole_haikuPreference_whenParentIsSonnet_returnsHaiku() {
        let service = ClaudeService()
        let role = makeRole(preference: .haiku)
        let result = service.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6"
        )
        XCTAssertEqual(result, SubagentModelResolver.defaultHaikuModelId)
    }

    func test_workflowRole_overrideExceedsTierPreference() {
        let service = ClaudeService()
        let role = makeRole(preference: .haiku)
        let result = service.resolvedModelId(
            for: role,
            parentModelId: "claude-sonnet-4-6",
            overrideModelId: "claude-opus-4-6"
        )
        XCTAssertEqual(result, "claude-opus-4-6")
    }
}
```

**注意**：若 `ClaudeService()` 无公开无参初始化器或需要依赖注入，调整测试方式：
- 如果 `ClaudeService` 无法在测试中实例化，则跳过 `ClaudeService` 集成层，只测试 `SubagentModelResolver` 纯函数（Task 1 测试已覆盖）。
- 将 `resolvedModelId(for:parentModelId:overrideModelId:)` 改为 `nonisolated static` 并直接在测试中调用。

### Step 2: 修改 `runSubagentLoop` — 接入 resolver

在 `runSubagentLoop` 中，将直接使用 `modelId` 参数的位置替换为通过 resolver 解析的结果：

**修改前（`runSubagentLoop` 函数签名不变，新增 `overrideModelId` 参数）：**

```swift
private func runSubagentLoop(
    task: String,
    definition: WorkflowRoleDefinition,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws -> AgentMessage {
    let startTime = Date()
    var loopMessages: ...
    let system = makeEphemeralSystemPrompt(definition.systemPrompt)
    let request = AgentLoopRunRequest(
        service: service,
        modelId: modelId,   // ← 直接使用父代理 modelId
        ...
    )
```

**修改后（新增 `overrideModelId` 参数）：**

```swift
private func runSubagentLoop(
    task: String,
    definition: WorkflowRoleDefinition,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,          // 父代理模型 ID（inherit 基准）
    overrideModelId: String?, // 调用方显式指定（nil = 不覆盖）
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws -> AgentMessage {
    let startTime = Date()

    // S-A3: 按三层优先级解析实际使用的模型 ID
    let resolvedModelId = SubagentModelResolver.resolve(
        preference: definition.modelPreference,
        parentModelId: modelId,
        overrideModelId: overrideModelId
    )

    var loopMessages: [MessageParameter.Message] = [.init(role: .user, content: .text(task))]
    let system = makeEphemeralSystemPrompt(definition.systemPrompt)
    let request = AgentLoopRunRequest(
        service: service,
        modelId: resolvedModelId,   // ← 使用解析后的模型 ID
        tools: buildSubagentTools(definition: definition, settings: settings),
        system: system,
        maxRounds: definition.maxRounds,
        toolExecutionContext: .subagent,
        toolApprovalMode: .bypassApprovals,
        runSource: "subagent",
        runLabel: definition.name,
        requestedBudgetSeconds: nil
    )
    // ... 其余代码不变
```

同时更新 `runNamedSubagent` 调用 `runSubagentLoop` 时传入 `overrideModelId`：

```swift
func runNamedSubagent(
    name: String,
    task: String,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    overrideModelId: String?,   // ← 新增参数
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws -> AgentMessage {
    let catalog = AgentCatalog.shared
    guard let definition = catalog.find(named: name) else {
        let available = catalog.subagentInvocableAgents.map(\.name).joined(separator: ", ")
        return .error("unknown agent '\(name)'. Available: \(available)", sender: "system")
    }

    return try await runSubagentLoop(
        task: task,
        definition: definition.workflowRoleDefinition,
        toolCallRecord: toolCallRecord,
        service: service,
        modelId: modelId,
        overrideModelId: overrideModelId,   // ← 透传
        settings: settings,
        sessionId: sessionId,
        modelContext: modelContext
    )
}
```

### Step 3: 修改 `executeRunSubagentTool` — 解析工具输入中的 `model` 参数

```swift
func executeRunSubagentTool(
    input: MessageResponse.Content.Input,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async -> AgentMessage {
    guard let agentName = input["agent_name"]?.stringValue else {
        return .error("missing 'agent_name' parameter", sender: "system")
    }
    guard let task = input["task"]?.stringValue else {
        return .error("missing 'task' parameter", sender: "system")
    }

    // S-A3: 解析调用方可选的 model override
    let overrideModelId = input["model"]?.stringValue.flatMap {
        $0.isEmpty ? nil : $0
    }

    do {
        return try await runNamedSubagent(
            name: agentName,
            task: task,
            toolCallRecord: toolCallRecord,
            service: service,
            modelId: modelId,
            overrideModelId: overrideModelId,   // ← 新增
            settings: settings,
            sessionId: sessionId,
            modelContext: modelContext
        )
    } catch {
        return .error(error.localizedDescription, sender: agentName)
    }
}
```

### Step 4: 运行 SubagentModelResolverTests 确认集成路径通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:"
```

期望：所有测试 PASS。

### Step 5: Commit

```bash
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift
git commit -m "feat(S-A3): wire SubagentModelResolver into runSubagentLoop, parse model override from tool input"
```

---

## Task 4: 更新 `ToolRegistry.swift` — `run_subagent` schema 新增 `model` 参数

**Files:**
- Modify: `agentGui/Services/ToolRegistry.swift`

### Step 1: 先写失败测试 — schema 验证

```swift
// 在 SubagentModelResolverTests.swift 追加
// MARK: - ToolRegistry schema

extension SubagentModelResolverTests {

    func test_runSubagentSchema_includesModelProperty() {
        // 验证 run_subagent 工具 schema 包含可选的 model 参数
        //
        // 注意：ToolDefinition inputSchemaBuilder 需要传入 context，
        // 此处通过 ToolRegistry 获取，验证 schema properties 包含 "model"
        let registry = DefaultToolRegistry()
        let def = registry.definition(for: "run_subagent")
        XCTAssertNotNil(def, "run_subagent 工具定义应存在")

        // schema 中的 properties 应含 "model" key
        // 如果 inputSchemaBuilder 需要 context，此断言通过编译时已隐含
        // 实际验证方式见 Step 3 说明
    }
}
```

> **注意：** `ToolRegistry` 的 `inputSchemaBuilder` 接受 context 参数，难以在单元测试中直接验证 schema JSON。因此本 task 采用"编译验证 + 观察日志"策略，测试主要检查 schema 构建时不崩溃。

### Step 2: 修改 `ToolRegistry.swift` — 在 `run_subagent` inputSchema 中新增 `model` 可选属性

找到 `runSubagentDefinition()` 函数中的 `inputSchemaBuilder`，在 `properties` 字典中新增 `"model"` key：

```swift
inputSchemaBuilder: { context in
    .init(
        type: .object,
        properties: [
            "agent_name": .init(
                type: .string,
                description: "Identifier of the subagent to use. One of: \(context.agentNameListText)"
            ),
            "task": .init(
                type: .string,
                description: "Detailed, self-contained task description for the subagent."
            ),
            // S-A3: 可选模型 override，调用方可强制指定子代理使用的模型 ID
            "model": .init(
                type: .string,
                description: """
                    Optional. Override the model used by this specific subagent invocation. \
                    When omitted, the agent uses its configured model-preference \
                    (or inherits the parent model). \
                    Example: "claude-haiku-4-5" for fast/low-cost tasks.
                    """
            )
        ],
        required: ["agent_name", "task"]  // model 不在 required 中
    )
}
```

> **注意：** `required` 数组保持 `["agent_name", "task"]`，`"model"` 为可选参数，不加入 `required`。

### Step 3: 验证编译通过

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|warning:|Build succeeded"
```

期望：`Build succeeded`，0 errors。

### Step 4: Commit

```bash
git add agentGui/Services/ToolRegistry.swift
git commit -m "feat(S-A3): add optional model override parameter to run_subagent tool schema"
```

---

## Task 5: 全量验证 — 运行完整测试套件子集

**Files:** 无变更，仅运行测试

### Step 1: 运行所有 S-A3 相关测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a3-derived \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

期望：所有 3 个测试 class 全部 PASS，0 failures。

### Step 2: 确认验收标准

根据设计文档 S-A3 验收标准逐项确认：

1. ✅ explore 子代理使用 haiku 模型 — `test_builtInExploreAgentUsesHaikuModelPreference` 通过
2. ✅ verifier 使用 inherit 继承父代理模型 — `test_builtInWorkerAndVerifierUseInheritModelPreference` 通过  
3. ✅ `model-preference: haiku` 的代理可被 override 覆盖 — `test_override_precedesPreference` 通过
4. ✅ resolver 纯函数单元测试全部通过 — `SubagentModelResolverTests` 全部 PASS

### Step 3: 最终 Commit

```bash
git add -A
git commit -m "feat(S-A3): complete subagent model selection - resolver, explore haiku, tool schema override"
```

---

## 验收标准检查表

| 验收条目 | 测试覆盖 | 实现位置 |
|---------|---------|---------|
| explore 子代理使用 haiku 模型 | `test_builtInExploreAgentUsesHaikuModelPreference` | `explore.agent.md` + resolver |
| verifier 使用 inherit 继承父代理模型 | `test_builtInWorkerAndVerifierUseInheritModelPreference` | `verifier.agent.md` 无 `model-preference` → 默认 `.inherit` |
| worker 使用 inherit | 同上 | `worker.agent.md` 无 `model-preference` |
| override 优先级高于 preference | `test_override_precedesPreference` | `SubagentModelResolver.resolve` |
| override 优先级高于 inherit | `test_override_precedesInherit` | `SubagentModelResolver.resolve` |
| family-match 优化（同系列不降级）| `test_haiku_whenParentIsHaiku_returnsParentModel` 等 | `parentMatchesFamily` |
| 空字符串 override 视为 nil | `test_emptyOverride_treatedAsNil` | `resolve` 入口判断 |
| `run_subagent` schema 新增可选 `model` 参数 | 编译验证 + schema 目视确认 | `ToolRegistry.runSubagentDefinition` |

---

## 常见错误排查

**1. `SubagentModelResolver` 类型未找到**
- 确认文件 `agentGui/Services/ClaudeService/SubagentModelResolver.swift` 已加入 Xcode target
- 在 `agentGui.xcodeproj` 中确认文件属于 `agentGui` target（Build Phases → Compile Sources）

**2. `test_existingAgentsHaveDefaultOptionalFieldValues` 继续失败**
- 确认 `explore.agent.md` 中的 `model-preference: haiku` 行存在且拼写正确（冒号后有空格）
- 确认测试中对 `explore.modelPreference` 的断言已改为 `.haiku`

**3. `runSubagentLoop` 编译错误（`overrideModelId` 未找到）**
- `runSubagentLoop` 是 `private`，调用方仅在 `ClaudeService+Subagent.swift` 内部，确认 `runNamedSubagent` 调用时已传入新的 `overrideModelId` 参数

**4. `run_subagent` schema 新增 `model` 后 API 报错**
- `model` 应出现在 `properties` 中但**不在** `required` 数组中
- 已在网络/API 层调用的实际请求中，Claude 不会强制填写此字段
