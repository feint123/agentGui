# Unified Tool Definition Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current duplicated tool schema and capability definitions with a single tool-definition source that is used consistently by the main agent, subagents, and workflow workers.

**Architecture:** Introduce a centralized tool-definition layer made of `ToolDefinition`, `ToolRegistry`, and `ToolsetResolver`, then move all tool-list construction to that layer. Replace role-level boolean capabilities with declarative tool grants and tool groups, while keeping existing tool executors and dispatch logic as implementation details rather than definition sources.

**Tech Stack:** Swift 6, Swift Testing, SwiftAnthropic, SwiftData, existing `ClaudeService`, workflow runtime, tool-call persistence, SwiftUI detail views.

---

## 1. 实施原则

- 先把“定义层”和“解析层”做成可测试纯模型，再替换主 Agent / subagent / workflow 的接线代码。
- 先完成 P0：单一工具定义源、统一注册、统一解析、移除重复 schema 文本；P1/P2 作为后续任务继续推进。
- 不做兼容迁移层。应用未上市，允许一次性替换现有重复定义路径。
- 保留现有工具执行器和工具结果模型，只把它们从“定义真源”降级为“执行细节”。
- 先补测试锁定主链路，再删除旧入口，避免改完后无法证明主 Agent / subagent / workflow 工具集合仍然正确。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolGrant.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolRegistryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowRoleToolGrantTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

## 3. 关键设计决策

### 3.1 什么是“定义真源”

V1 中下列信息必须只在 `ToolDefinition` 中出现一次：

- tool id
- 展示名与描述
- schema version
- base input schema
- 风险级别
- 支持上下文
- 执行器绑定 key

下列内容不再允许在 `ClaudeService+ToolBuilder`、`ClaudeService+Subagent`、`WorkflowAgentRunner.WorkflowToolStub` 中重复手写：

- `bash` schema 文本
- `str_replace_based_edit_tool` schema 文本
- `web_search` / `web_fetch` schema 文本
- `run_subagent` / `start_workflow` 的参数定义文本

### 3.2 什么是“grant”

V1 用 `ToolGrant` 统一表达角色或上下文可用工具。grant 最少包含：

- `toolID` 或 `toolGroupID`
- `accessMode`
- `parameterPolicy`
- `allowedContexts`

第一版不要过度设计复杂 ACL。只要能覆盖以下差异即可：

- 只读文件工具 vs 读写文件工具
- bash 全量模式 vs 限制模式
- story memory 工具组单独授予
- workflow artifact 工具只给 workflow worker

### 3.3 什么是“解析结果”

`ToolsetResolver` 输出至少包括：

- 实际暴露的 `MessageParameter.Tool` 列表
- 每个工具对应的 `ToolDefinition`
- 暴露来源，例如 role grant / main policy / workflow policy
- 未暴露原因，供调试和详情页使用

V1 先把解析结果用于内部测试和 Tool Call 元数据，不急着做完整设置页。

### 3.4 哪些旧结构必须直接移除

本计划执行完成后，下列结构不应继续承载工具定义职责：

- `ClaudeService+Subagent.buildSubagentTools(...)` 中的重复 schema 文本
- `WorkflowAgentRunner.WorkflowToolStub.buildTools()` 中的重复 schema 文本
- `WorkflowRoleDefinition` 中持续膨胀的 `enableTextEditor` / `enableBash` / `enableWebSearch` / `enableWebFetch` / `enableStoryMemoryTools`

如果为了短期编译稳定保留 helper，也只能变成对 `ToolRegistry` 的薄封装，不能继续保存独立 schema。

## 4. 任务拆解

### Task 1: 建立统一工具定义与注册中心

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolRegistryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`

**Step 1: 写失败测试，固定注册中心契约**

新增 `ToolRegistryTests.swift`，覆盖以下行为：

- 注册中心能返回 `bash`、`str_replace_based_edit_tool`、`web_search`、`web_fetch`、`run_subagent`、`start_workflow`
- 同一工具的 schema 字段来自统一定义对象，而不是构建函数拼接副本
- 所有返回给 Anthropic 的工具都带 `ephemeral` cache control

测试示例：

```swift
import Foundation
import SwiftAnthropic
import Testing
@testable import agentGui

struct ToolRegistryTests {

    @Test func registryContainsCoreBuiltInTools() throws {
        let registry = DefaultToolRegistry()

        #expect(registry.definition(for: "bash") != nil)
        #expect(registry.definition(for: "str_replace_based_edit_tool") != nil)
        #expect(registry.definition(for: "run_subagent") != nil)
    }

    @Test func toolDefinitionBuildsAnthropicToolFromSingleSchemaSource() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "bash"))
        let tool = definition.makeAnthropicTool()

        let payload = try #require(encodedToolDictionary(from: tool))
        let schema = try #require(payload["input_schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(properties.keys.contains("execution_mode"))
        #expect((payload["cache_control"] as? [String: String])?["type"] == "ephemeral")
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolRegistryTests
```

Expected: FAIL，因为 `ToolDefinition`、`DefaultToolRegistry`、`makeAnthropicTool()` 还不存在。

**Step 3: 写最小实现**

在 `ToolDefinition.swift` 中实现最小模型，建议字段如下：

```swift
enum ToolCategory: String, Codable, Sendable {
    case editor
    case shell
    case web
    case workflow
    case memory
    case system
}

enum ToolContext: String, Codable, Hashable, Sendable {
    case mainAgent
    case subagent
    case workflowWorker
}

struct ToolDefinition: Sendable {
    let id: String
    let displayName: String
    let description: String
    let category: ToolCategory
    let schemaVersion: Int
    let supportedContexts: Set<ToolContext>
    let makeInputSchema: () -> MessageParameter.Tool.InputSchema
    let executorKey: String

    func makeAnthropicTool() -> MessageParameter.Tool { ... }
}
```

在 `ToolRegistry.swift` 中实现默认注册中心，先只注册现有内置工具与现有 workflow 工具入口。

此阶段先不要做 resolver，只先把定义真源立起来。

**Step 4: 让 `ClaudeService+ToolBuilder` 先读注册中心构造主 Agent 工具**

把当前 `buildTools(...)` 中最基础的内置工具改为从注册中心读取，但先保留过滤逻辑在 `buildTools(...)` 内。

目标是让 `BashToolSchemaTests` 仍能通过，同时 `ToolRegistryTests` 开始通过。

**Step 5: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolRegistryTests -only-testing:agentGuiTests/BashToolSchemaTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Models/ToolDefinition.swift agentGui/Services/ToolRegistry.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGuiTests/ToolRegistryTests.swift agentGuiTests/BashToolSchemaTests.swift
git commit -m "feat: add centralized tool definitions and registry"
```

### Task 2: 建立 ToolGrant 与 ToolsetResolver，替换角色布尔能力表达

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolGrant.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowRoleToolGrantTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: 写失败测试，固定 grant 语义与角色映射**

新增两组测试：

- `ToolsetResolverTests.swift`
- `WorkflowRoleToolGrantTests.swift`

覆盖以下行为：

- `planner` 只能解析出只读文件工具，不包含 `bash`
- `coder` 解析出读写文件工具和 `bash`
- `creative_memory_manager` 解析出 story memory 工具组，但不包含通用代码编辑工具
- 用户关闭 `enableWebSearchTool` 时，即使 role grant 了 Web 工具，也不返回 `web_search`

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct WorkflowRoleToolGrantTests {

    @Test func coderRoleResolvesEditorAndShellTools() throws {
        let role = try #require(WorkflowRoleDefinition.find(named: "coder"))
        let settings = AppSettings()
        settings.enableBashTool = true

        let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
            .init(context: .subagent, role: role, settings: settings)
        )

        #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
        #expect(result.toolIDs.contains("bash"))
    }
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolsetResolverTests -only-testing:agentGuiTests/WorkflowRoleToolGrantTests
```

Expected: FAIL，因为 grant/resolver 体系还不存在。

**Step 3: 写最小实现**

在 `ToolGrant.swift` 中实现最小模型，建议：

```swift
enum ToolAccessMode: String, Codable, Sendable {
    case readOnly
    case readWrite
    case unrestricted
}

enum ToolGroupID: String, Codable, Sendable {
    case readOnlyEditor
    case readWriteEditor
    case web
    case shell
    case storyMemory
    case workflowArtifact
}

struct ToolGrant: Sendable, Hashable {
    let toolID: String?
    let toolGroupID: ToolGroupID?
    let accessMode: ToolAccessMode
    let parameterPolicy: ToolParameterPolicy
    let allowedContexts: Set<ToolContext>
}
```

在 `WorkflowRoleDefinition.swift` 中：

- 新增 `toolGrants: [ToolGrant]`
- 为每个内置 role 填写 grants
- 删除或废弃 `enableTextEditor`、`enableBash`、`enableWebSearch`、`enableWebFetch`、`enableStoryMemoryTools`

同步更新 `StoryMemoryPromptAssemblerTests.swift` 中对 role 布尔字段的断言，改为校验 resolver 结果而不是旧字段。

**Step 4: 实现 `DefaultToolsetResolver`**

`resolve(...)` 最少完成：

- 展开 tool groups
- 检查 role grants
- 检查 `supportedContexts`
- 检查 `AppSettings` 的工具开关
- 返回 `resolvedTools`、`excludedTools`

第一版先把 `parameterPolicy` 做成最小枚举占位即可，真实 schema 裁剪放到 Task 5。

**Step 5: 跑 focused tests**

Run 同 Step 2，再加：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Models/ToolGrant.swift agentGui/Services/ToolsetResolver.swift agentGui/Models/WorkflowRoleDefinition.swift agentGuiTests/ToolsetResolverTests.swift agentGuiTests/WorkflowRoleToolGrantTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "feat: replace workflow role tool booleans with grants"
```

### Task 3: 统一 main agent / subagent / workflow worker 的工具构建入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: 写失败测试，固定三条执行路径的工具一致性**

在 `ToolsetResolverTests.swift` 或新增测试中覆盖：

- main agent 构建工具时包含 `run_subagent`、`start_workflow`
- subagent 构建工具时不包含 `run_subagent`
- workflow worker 的 `coder` 能拿到与 subagent `coder` 等价的核心工具集合
- `creative_memory_manager` 在 subagent 路径仍只暴露 story memory 工具组

建议新增一个辅助断言函数，只比较 tool id 集合，不比较描述文本。

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolsetResolverTests -only-testing:agentGuiTests/BashToolSchemaTests -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: FAIL，因为 subagent 和 workflow 仍使用各自独立构建逻辑。

**Step 3: 改造主 Agent 工具构建**

在 `ClaudeService+ToolBuilder.swift` 中：

- 让 `buildTools(...)` 改为创建 `ToolResolutionRequest`
- 调用 `DefaultToolsetResolver`
- 只保留 main-agent 特有策略拼装，不再手写工具 schema

**Step 4: 改造 subagent 工具构建**

在 `ClaudeService+Subagent.swift` 中：

- 删除 `buildSubagentTools(...)` 内的重复 schema 文本
- 改为通过 role grants + resolver 生成工具列表
- 保留 story memory 相关执行逻辑，但不要再靠名称前缀筛选定义源

**Step 5: 改造 workflow worker 工具构建**

在 `WorkflowAgentRunner.swift` 中：

- 删除 `WorkflowToolStub.buildTools()` 作为独立真源
- 改为通过 registry + resolver 生成 role 对应工具集
- 仅把 `emit_workflow_artifact` 作为临时补充项接入；下一任务再将其正式注册

**Step 6: 跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 7: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift agentGuiTests/BashToolSchemaTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift agentGuiTests/ToolsetResolverTests.swift
git commit -m "refactor: route agent tool construction through unified resolver"
```

### Task 4: 统一工具执行绑定与工具记录元数据

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolDispatchBindingTests.swift`

**Step 1: 写失败测试，固定定义层与执行层绑定关系**

新增 `ToolDispatchBindingTests.swift`，覆盖：

- `bash` 的 `executorKey` 能映射到现有 bash 执行器
- `run_subagent` 与 `start_workflow` 不依赖散落的 schema 构造字符串即可完成分发
- 未注册工具会返回 unknown tool

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ToolDispatchBindingTests {

    @Test func registryBackedExecutorKeyMapsToKnownDispatchPath() throws {
        let registry = DefaultToolRegistry()
        let definition = try #require(registry.definition(for: "bash"))

        #expect(definition.executorKey == "builtin.bash")
    }
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolDispatchBindingTests
```

Expected: FAIL，因为当前定义层没有执行器绑定字段可用。

**Step 3: 写最小实现**

在 `ClaudeService+ToolDispatch.swift` 中：

- 引入从 `ToolRegistry` 查定义的步骤
- 用 `executorKey` 或 `toolID` 分发到现有执行器
- 先保持 `switch` 分发，但 switch 的输入来源改为定义层，而不是把字符串名字和定义层彻底脱钩

在 `ClaudeService+ToolCallRecord.swift` 中：

- 给 ToolCall 增加最少元数据字段，建议：
  - `toolDefinitionID`
  - `toolSchemaVersion`
  - `toolExposureSource`
- record factory 从 resolver/definition 填充这些字段

如果 `ToolCall.swift` 需要新增持久化字段，就在这一任务一起完成。

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolDispatchBindingTests -only-testing:agentGuiTests/BashToolSchemaTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolDispatch.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Models/ToolCall.swift agentGuiTests/ToolDispatchBindingTests.swift
git commit -m "feat: bind tool execution and records to registry definitions"
```

### Task 5: 为同一工具支持参数级裁剪，而不是复制简化 schema

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolGrant.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolSchemaPolicyTests.swift`

**Step 1: 写失败测试，固定裁剪语义**

新增 `ToolSchemaPolicyTests.swift`，覆盖：

- 只读编辑 grant 下，`str_replace_based_edit_tool` 只暴露 `view` 相关命令
- 限制型 bash grant 下，不暴露 `background` 或 `interactive`
- 全量 `coder` grant 下，仍保留当前 bash managed-task 字段

测试示例：

```swift
import Foundation
import Testing
@testable import agentGui

struct ToolSchemaPolicyTests {

    @Test func readOnlyEditorPolicyRemovesWriteCommands() throws {
        let registry = DefaultToolRegistry()
        let resolver = DefaultToolsetResolver(registry: registry)
        let result = resolver.resolve(.fixtureReadOnlyEditor())
        let tool = try #require(result.tool(named: "str_replace_based_edit_tool"))

        let commands = schemaEnumValues(tool: tool, property: "command")
        #expect(commands == ["view"])
    }
}
```

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolSchemaPolicyTests
```

Expected: FAIL，因为 resolver 还没有 schema policy 能力。

**Step 3: 写最小实现**

在 `ToolGrant.swift` 中引入最小 `ToolParameterPolicy`，例如：

```swift
enum ToolParameterPolicy: Hashable, Sendable {
    case inherit
    case editorViewOnly
    case bashNoBackground
    case bashForegroundOnly
}
```

在 `ToolDefinition` 中提供一个从 base schema 派生裁剪 schema 的能力，例如：

- `func anthropicTool(applying policy: ToolParameterPolicy) -> MessageParameter.Tool`

不要复制第二份 tool definition。裁剪必须基于同一个 base schema 完成。

**Step 4: 跑 focused tests**

Run 同 Step 2，再加：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashToolSchemaTests
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/ToolDefinition.swift agentGui/Models/ToolGrant.swift agentGui/Services/ToolsetResolver.swift agentGuiTests/ToolSchemaPolicyTests.swift
git commit -m "feat: support grant-based tool schema policies"
```

### Task 6: 把 workflow 专用工具和可观测性接入统一目录

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolCallDetailPresentationTests.swift`

**Step 1: 写失败测试，固定详情页应展示的统一定义元数据**

更新 `ToolCallDetailPresentationTests.swift`，覆盖：

- Tool Call 详情显示 tool definition id
- Tool Call 详情显示 schema version
- Tool Call 详情显示暴露来源，例如 `role:coder` / `policy:mainAgentDefault`

若现有测试文件不便扩展，可新增小测试文件专门断言 `ToolCallDetailPresentation` 的 section 文本。

**Step 2: 跑 focused tests，确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: FAIL，因为 `ToolCall` 详情尚未展示这些字段。

**Step 3: 把 `emit_workflow_artifact` 注册进 ToolRegistry**

不要继续让它只存在于 `WorkflowAgentRunner.makeEmitArtifactTool()` 中。改为：

- 在 `ToolRegistry` 中注册 `emit_workflow_artifact`
- 由 workflow-specific grant 或 resolver 决定何时暴露

然后删除 `WorkflowAgentRunner` 中对该工具的独立 schema 构造逻辑。

**Step 4: 更新 Tool Call 详情展示**

在 `ToolCallDetailContentView.swift` 中增加统一元数据 section，例如：

- 工具定义 ID
- schema 版本
- 暴露来源
- 执行上下文

此阶段只补详情展示，不做新的设置页。

**Step 5: 跑 focused tests**

Run 同 Step 2，再加：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolsetResolverTests
```

Expected: PASS。

**Step 6: Commit**

```bash
git add agentGui/Services/WorkflowAgentRunner.swift agentGui/Services/ToolRegistry.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/ToolCallDetailPresentationTests.swift
git commit -m "feat: register workflow artifact tool and expose tool metadata in UI"
```

### Task 7: 跑整体验证并清理残留旧入口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-12-unified-tool-definition-requirements.md`

**Step 1: 搜索残留重复定义点**

Run:

```bash
rg "WorkflowToolStub|buildSubagentTools\(|enableTextEditor|enableBash|enableWebSearch|enableWebFetch|enableStoryMemoryTools" agentGui agentGuiTests
```

Expected: 只剩必要兼容注释或零结果；不应再有生产代码依赖这些旧入口。

**Step 2: 删除或收口残留 helper**

把以下旧入口删掉或变成直接调用 registry/resolver 的薄封装：

- `buildSubagentTools(...)`
- `WorkflowToolStub`
- role 布尔字段相关逻辑

若测试 helper 仍引用旧名字，同步重命名到新抽象，避免“实现已换、测试名还在旧世界”的状态。

**Step 3: 跑核心测试矩阵**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolRegistryTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/WorkflowRoleToolGrantTests \
  -only-testing:agentGuiTests/ToolDispatchBindingTests \
  -only-testing:agentGuiTests/ToolSchemaPolicyTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/ToolCallDetailPresentationTests
```

Expected: PASS。

**Step 4: 跑质量冒烟**

Run workspace task: `Quality Smoke`

Expected: PASS，且没有因工具定义重构引入新的 UI 或 agent-loop 回归。

**Step 5: 更新需求文档状态说明**

在需求文档末尾补一小段实现状态或链接到本计划，避免后续继续按旧方向写方案。

**Step 6: Commit**

```bash
git add agentGui agentGuiTests docs/spec/2026-03-12-unified-tool-definition-requirements.md
git commit -m "refactor: unify tool definitions across agent contexts"
```

## 5. 风险与检查点

### 风险 1: `MessageParameter.Tool.InputSchema` 裁剪实现成本高

如果 SwiftAnthropic 的 schema 类型不易原地修改，优先策略是：

- 在 `ToolDefinition` 内维护可生成字典式 schema 的 builder
- 最后一步再转为 `MessageParameter.Tool`

不要因为 SDK 类型不方便，就回退到多处复制 schema 文本。

### 风险 2: 旧测试大量依赖 role 布尔字段

`StoryMemoryPromptAssemblerTests.swift` 已存在对 `enableBash`、`enableStoryMemoryTools` 的断言。需要尽早改为断言 resolver 结果，否则后续每一步都会被旧语义拖住。

### 风险 3: `run_subagent` / `start_workflow` 描述文本较长，容易在重构中丢失提示质量

在 Task 1 和 Task 3 中保留现有描述文本内容，不要先压缩文案。重构重点是来源统一，不是文案重写。

### 风险 4: UI 可观测性字段进入 `ToolCall` 可能影响 SwiftData 模型稳定性

新增字段时只加最小必要字段，避免顺手塞入完整 `ToolResolutionResult`。详情页只需要展示摘要字段。

## 6. 完成定义

满足以下条件才算该计划完成：

- 主 Agent、subagent、workflow worker 的工具 schema 都来自统一注册中心
- `WorkflowRoleDefinition` 不再以布尔能力字段作为主表达方式
- `WorkflowToolStub` 和 subagent 内重复 schema 文本已删除或退化为无定义职责的薄封装
- 工具执行分发与 ToolCall 记录能够关联统一定义元数据
- 详情页能看到工具定义 ID、schema 版本和暴露来源
- 核心测试矩阵与 `Quality Smoke` 全部通过