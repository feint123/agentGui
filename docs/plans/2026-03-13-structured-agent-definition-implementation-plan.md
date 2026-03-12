# Structured Agent Definition Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace hardcoded built-in subagent role definitions with bundle-loaded Markdown agent documents, and converge the runtime to exactly three built-in roles: `explore`, `worker`, and `verifier`.

**Architecture:** Introduce a document layer (`AgentDefinitionDocument`), a loader/validator (`AgentDefinitionLoader`), and a runtime registry (`AgentCatalog`) so all agent identity, prompt text, tool grants, and visibility rules come from one validated source. Then rewire `run_subagent`, tool schema text, system prompt generation, tool-call presentation, and tests to consume that registry instead of `WorkflowRoleDefinition.all`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, SwiftAnthropic, Xcode bundle resources, existing `ToolRegistry` / `ToolsetResolver` / `ClaudeService` runtime.

---

## 1. 实施原则

- 先锁定测试，再切换真源；不要先删旧角色再补校验，否则很容易进入半迁移状态。
- 保留运行时强类型，但不保留硬编码内容真源；`WorkflowRoleDefinition` 可以继续存在，但只能承载解析产物。
- 三角色收敛一次完成，不做长期兼容壳；旧角色只允许在错误提示里明确告知已移除。
- Agent 文案改动应主要落在 `.agent.md` 文件，Swift 改动聚焦于加载、校验、接线和展示。
- 所有文本入口必须统一到 `AgentCatalog`，包括 `run_subagent` 参数说明、主系统提示、工具调用记录标题、测试断言。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentDefinitionDocument.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentRuntimeDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentDefinitionLoader.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentCatalog.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/AgentValidationError.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/explore.agent.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/worker.agent.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentDefinitionLoaderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentCatalogTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowRoleToolGrantTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

## 3. 关键设计约束

### 3.1 文档层与运行时层必须分离

- `AgentDefinitionDocument` 只保留 frontmatter 原始字段和 Markdown 正文。
- `AgentRuntimeDefinition` 负责强类型字段、工具授权、预算、可见性、展示名称。
- `WorkflowRoleDefinition` 如果保留，只能由 `AgentRuntimeDefinition` 映射生成，不能再声明内置角色正文。

### 3.2 frontmatter 必须严格校验

最低必填字段：

- `name`
- `display-name`
- `description`
- `argument-hint`
- `tools`
- `max-turns`
- `user-invocable`
- `subagent-invocable`
- `output-contract`

未知字段不允许静默通过。第一版可以先统一视为错误，等后续确有扩展需要再降为显式 warning。

### 3.3 三角色职责必须在文档里可直接辨识

- `explore`：只读探索，不改文件，不跑 shell，不声称已完成实现。
- `worker`：实施变更，可读写文件，可运行必要验证，不承担最终审查结论。
- `verifier`：审核结果和证据，默认只读，默认不编辑，不以模糊措辞替代验证结论。

### 3.4 `AgentCatalog` 是唯一真源

以下文本和行为都必须通过 `AgentCatalog` 获取：

- `run_subagent` 可选 agent 列表
- `run_subagent` 工具描述中的 agent 说明
- 主系统提示中的 subagent 路由说明
- 工具调用记录中的子代理标题
- 测试里对内置角色集合的断言

## 4. 任务拆解

### Task 1: 先写加载器与目录测试，锁定三角色契约

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentDefinitionLoaderTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentCatalogTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowRoleToolGrantTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`

**Step 1: 写失败测试，固定加载契约**

新增 `AgentDefinitionLoaderTests.swift`，至少覆盖：

- 三份合法文档可成功加载
- 缺少必填字段时报错
- 重复 `name` 报错
- 未知工具组报错
- 正文为空报错

测试骨架：

```swift
import Foundation
import Testing
@testable import agentGui

struct AgentDefinitionLoaderTests {

    @Test func loadsThreeBuiltInAgentDocuments() throws {
        let loader = AgentDefinitionLoader()
        let documents = try loader.loadBuiltInDocuments(from: .main)

        #expect(documents.map(\.name).sorted() == ["explore", "verifier", "worker"])
    }

    @Test func rejectsUnknownToolGroup() throws {
        let loader = AgentDefinitionLoader()

        #expect(throws: AgentValidationError.self) {
            try loader.parseDocument(named: "bad.agent.md", raw: """
            ---
            name: explore
            display-name: 探索者
            description: desc
            argument-hint: hint
            tools: [imaginary_group]
            max-turns: 6
            user-invocable: false
            subagent-invocable: true
            output-contract: exploration_report
            ---
            # Role
            body
            """)
        }
    }
}
```

**Step 2: 写失败测试，固定目录查询契约**

新增 `AgentCatalogTests.swift`，至少覆盖：

- `all.count == 3`
- `find(named: "explore")` / `find(named: "worker")` / `find(named: "verifier")` 成功
- 不存在旧角色名
- `subagentInvocableAgents` 与 `agentNameListText` 一致

**Step 3: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentDefinitionLoaderTests \
  -only-testing:agentGuiTests/AgentCatalogTests
```

Expected: FAIL，因为加载器、目录和资源文件还不存在。

**Step 4: 改造旧测试，让它们表达新角色语义**

- `WorkflowRoleToolGrantTests.swift`：删除 `planner` / `coder` 断言，改为 `explore` / `worker` / `verifier`
- `ToolsetResolverTests.swift`：把 `explorer` 改为 `explore`，删除 `creative_memory_manager` 相关断言

**Step 5: Commit**

```bash
git add agentGuiTests/AgentDefinitionLoaderTests.swift agentGuiTests/AgentCatalogTests.swift agentGuiTests/WorkflowRoleToolGrantTests.swift agentGuiTests/ToolsetResolverTests.swift
git commit -m "test: lock structured agent loading contract"
```

### Task 2: 增加文档模型、frontmatter 解析与严格校验

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentDefinitionDocument.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentRuntimeDefinition.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentDefinitionLoader.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/AgentValidationError.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SkillService.swift`

**Step 1: 先抽出可复用 frontmatter 解析能力**

参考 `SkillService.parseFrontmatter(at:)` 的现有做法，把“读取 frontmatter + 去引号 + 取正文”抽到独立类型，例如：

```swift
struct ParsedFrontmatterDocument: Sendable {
    let fields: [String: String]
    let body: String
}

enum FrontmatterParser {
    static func parse(raw: String) throws -> ParsedFrontmatterDocument { ... }
}
```

要求：

- 支持数组字段的第一版简单解析
- 正文为空白时报错
- frontmatter 未闭合时报错

**Step 2: 定义文档层与运行时层模型**

建议最小形态：

```swift
struct AgentDefinitionDocument: Sendable {
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let tools: [String]
    let maxTurns: Int
    let userInvocable: Bool
    let subagentInvocable: Bool
    let outputContract: String
    let body: String
}

struct AgentRuntimeDefinition: Sendable {
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let systemPrompt: String
    let maxTurns: Int
    let outputContract: String
    let toolGrants: [ToolGrant]
    let userInvocable: Bool
    let subagentInvocable: Bool
}
```

**Step 3: 实现 `AgentDefinitionLoader`**

职责：

- 从 `Bundle` 的 `Resources/Agents` 扫描 `*.agent.md`
- 调用解析器生成 `AgentDefinitionDocument`
- 校验字段和值
- 把 `tools` 转为允许的 `ToolGrant`
- 生成 `[AgentRuntimeDefinition]`

至少要校验：

- `name` 仅允许 `explore` / `worker` / `verifier`
- 重复 `name` 直接失败
- `max-turns > 0`
- `tools` 全部可映射到已知工具组
- `user-invocable` 与 `subagent-invocable` 组合合法

**Step 4: 跑 focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentDefinitionLoaderTests \
  -only-testing:agentGuiTests/AgentCatalogTests \
  -only-testing:agentGuiTests/ToolsetResolverTests
```

Expected: `AgentDefinitionLoaderTests` 与基础模型测试 PASS；目录接线类测试可能仍部分失败，属于预期。

**Step 5: Commit**

```bash
git add agentGui/Models/AgentDefinitionDocument.swift agentGui/Models/AgentRuntimeDefinition.swift agentGui/Services/AgentDefinitionLoader.swift agentGui/Utilities/AgentValidationError.swift agentGui/Services/SkillService.swift
git commit -m "feat: add structured agent document loader"
```

### Task 3: 编写三份内置 Agent 文档并接入 Bundle

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/explore.agent.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/worker.agent.md`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/Agents/verifier.agent.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`

**Step 1: 先写三份高质量正文**

统一采用以下骨架：

```md
---
name: explore
display-name: 探索者
description: 搜索代码、文档和批准的网页来源，返回结构化上下文。
argument-hint: Describe what to search for and desired thoroughness.
tools: [read_only_editor, web]
max-turns: 10
user-invocable: false
subagent-invocable: true
output-contract: exploration_report
---

# Role

...

## Use When

...

## Do Not Use When

...

## Working Style

...

## Tool Discipline

...

## Output

...
```

文案要求：

- 不写旧角色名
- 不堆砌口号式措辞
- 输出部分明确结构化结果字段
- `verifier` 可以附 1 到 2 个微型输出示例，但不要写成长教程

**Step 2: 把 `Resources/Agents` 加入目标资源**

在 `project.pbxproj` 中完成资源接线，确保：

- App target 能打包三份 `.agent.md`
- Unit test target 能读取这些文件，必要时也加入测试资源

**Step 3: 运行资源完整性与加载测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentDefinitionLoaderTests \
  -only-testing:agentGuiTests/AgentCatalogTests
```

Expected: PASS，且测试能证明资源确实进入 bundle 或可访问的测试路径。

**Step 4: Commit**

```bash
git add agentGui/Resources/Agents agentGui.xcodeproj/project.pbxproj agentGuiTests/AgentDefinitionLoaderTests.swift agentGuiTests/AgentCatalogTests.swift
git commit -m "feat: add built-in structured agent documents"
```

### Task 4: 建立 `AgentCatalog`，替换运行时查找真源

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentCatalog.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`

**Step 1: 实现唯一目录接口**

目录接口至少提供：

```swift
protocol AgentCatalogProtocol: Sendable {
    var all: [AgentRuntimeDefinition] { get }
    var subagentInvocableAgents: [AgentRuntimeDefinition] { get }
    func find(named name: String) -> AgentRuntimeDefinition?
    var agentListText: String { get }
    var agentNameListText: String { get }
}
```

第一版可以用 eager singleton，但必须支持测试注入。

**Step 2: 让 `WorkflowRoleDefinition` 退化为运行时映射层**

做法二选一，优先推荐 A：

- A. 直接让工作流代码改吃 `AgentRuntimeDefinition`
- B. 暂时保留 `WorkflowRoleDefinition` 结构，但由 `AgentCatalog` 构造 `all` 和 `find(named:)`

推荐 A 的原因：可以更快削掉旧角色静态定义和大段系统提示。

**Step 3: 切换 `ClaudeService+Subagent` 查找入口**

把：

```swift
guard let definition = WorkflowRoleDefinition.find(named: name) else {
```

替换为：

```swift
guard let definition = agentCatalog.find(named: name) else {
```

并在报错里返回真实可用列表：`explore, worker, verifier`。

**Step 4: 跑 subagent 与工作流相关测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/WorkflowRoleToolGrantTests
```

Expected: PASS；若仍有 `coder` / `planner` 之类残留调用，应在这一轮暴露出来并修掉。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentCatalog.swift agentGui/Models/WorkflowRoleDefinition.swift agentGui/Services/WorkflowAgentRunner.swift agentGui/Services/ClaudeService+Subagent.swift
git commit -m "refactor: route runtime agent lookup through catalog"
```

### Task 5: 让工具 schema 与系统提示都从目录生成

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: 改造 `ToolDefinitionBuildContext`**

把：

```swift
let availableAgents: [WorkflowRoleDefinition]
```

改成目录驱动，例如：

```swift
let agentCatalog: AgentCatalogProtocol
```

并让：

- `agentListText` 只列出 `subagentInvocableAgents`
- `agentNameListText` 只拼出当前可调用的 agent name

**Step 2: 重写 `run_subagent` 工具说明**

要求：

- 说明里只出现 `explore` / `worker` / `verifier`
- 研究任务优先 `explore`
- 实施任务优先 `worker`
- 验证任务优先 `verifier`

**Step 3: 重写主系统提示中的 subagent 路由规则**

把 `ACPClientService.buildSystemPrompt(...)` 里旧角色说明全部删掉，改成三角色版本。

需要新增文本级回归断言：

- 包含 `explore` / `worker` / `verifier`
- 不包含 `planner` / `coder` / `reviewer` / `executor` / `creative_memory_manager` / `writer`

**Step 4: 运行文本与 schema 回归测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests \
  -only-testing:agentGuiTests/AgentCatalogTests
```

Expected: PASS，且 `run_subagent` schema 文本与主系统提示都只反映新目录。

**Step 5: Commit**

```bash
git add agentGui/Models/ToolDefinition.swift agentGui/Services/ToolRegistry.swift agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ACPClientService.swift agentGuiTests/BashToolSchemaTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "refactor: generate subagent tool text from agent catalog"
```

### Task 6: 收敛展示层、清理旧角色残留并跑完整回归

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: 统一展示层的 agent 名称来源**

在 `ClaudeService+ToolCallRecord.swift` 中，把：

```swift
let definition = WorkflowRoleDefinition.find(named: agentName)
```

切到 `AgentCatalog`，确保：

- 标题显示新 display name
- 不再对 `creative_memory_manager` 做特判
- 遇到旧角色名只显示明确错误，不做静默映射

**Step 2: 检查 UI 层图标或文案分支**

如果 `ToolCallBubbleView` 或 `ToolCallDetailContentView` 对旧角色名做了特殊处理，同步删掉并改为目录驱动展示。

**Step 3: 全量搜索旧角色残留并清零**

Run:

```bash
rg -n 'planner|explorer|coder|reviewer|executor|creative_memory_manager|writer' agentGui agentGuiTests
```

Expected: 仅剩需求文档、历史计划或明确的错误提示文本；运行时代码和活跃测试中不再残留旧角色名。

**Step 4: 跑完整回归**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

如果时间允许，再跑任务：

```bash
./scripts/run_quality_smoke.sh
```

Expected: 全部通过；若 `Quality Smoke` 失败，记录失败范围，不要顺手扩修与本需求无关的问题。

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "refactor: converge runtime and presentation to three built-in agents"
```

## 5. 验收清单

- `AgentCatalog.all.count == 3`
- `run_subagent` 可用列表只包含 `explore`、`worker`、`verifier`
- 主系统提示不再出现旧角色名
- 三份 `.agent.md` 文件能从 bundle 正常加载
- `WorkflowRoleDefinition` 不再承载大段硬编码角色正文
- 旧角色调用返回明确错误，而不是偷偷映射
- UI / 审计 / 工具记录里不再暴露旧角色名称
- 相关单测与完整测试通过

## 6. 风险与回退点

- `project.pbxproj` 当前资源阶段为空，资源接线是高风险点；必须优先验证 bundle 实际包含 `.agent.md` 文件。
- `ToolDefinitionBuildContext.default` 当前静态依赖 `WorkflowRoleDefinition.all`，切换时容易影响主 Agent 与 subagent 的 schema 文本；这一步必须配合文本级回归测试一起改。
- `StoryMemoryPromptAssemblerTests.swift` 目前仍依赖 `creative_memory_manager` 语义，执行时要明确是删除该覆盖还是改成新的 `explore` / `worker` 协作断言，避免测试空心化。
- 如果工作流 runtime 对 `WorkflowRoleDefinition` 类型依赖太深，可先做映射层过渡，但必须在本需求结束前删除旧静态角色常量。

## 7. 建议执行顺序

1. 先做 Task 1 和 Task 2，把加载器、目录、校验和测试样本稳定下来。
2. 再做 Task 3 和 Task 4，完成资源接线和运行时真源切换。
3. 最后做 Task 5 和 Task 6，统一文本入口、展示入口和回归验证。
