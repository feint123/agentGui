# S-B1 Plan Built-in Agent — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增 `plan.agent.md` 内置代理，安排探索者专用只读架构规划代理（plan agent），使主代理可通过 `run_subagent agent_name: plan` 将只读探索与方案设计委托出去，减少主 loop token 压力，并产出结构化 `.plan` 工产物。

**Architecture:** 在现有 `.agent.md` → `AgentDefinitionLoader` → `AgentRuntimeDefinition` 流水线中写入一个新文件即可完成 90% 的工作；唯一代码改动是在 `AgentRuntimeDefinition.make(from:)` 的 `switch` 中为 `"plan"` 补充 artifact 绑定（readable/writable/primary），其余字段（model-preference、omit-main-context、output-contract、disallowed-tools 等）均已由 S-A1 实现的通用解析路径覆盖。

**Tech Stack:** Swift 6, XCTest（`@testable import agentGui`），`.agent.md` frontmatter，`AgentRuntimeDefinition.make(from:)` 的 `switch` 分支

**前置条件：** S-A1（开放代理定义体系）、S-A3（模型选择）、S-A4（omit-main-context）均已在 `main` 合并。

---

## 关键文件位置速查

| 类型 | 路径 |
|------|------|
| 待创建代理文件 | `agentGui/Resources/Agents/plan.agent.md` |
| Agent runtime 映射 | `agentGui/Models/AgentRuntimeDefinition.swift` |
| 代理加载器 | `agentGui/Services/AgentDefinitionLoader.swift` |
| 工产物枚举 | `agentGui/Models/WorkflowModels.swift` |
| 现有相似代理 | `agentGui/Resources/Agents/explore.agent.md` |
| 新增测试文件 | `agentGuiTests/PlanAgentDefinitionTests.swift` |
| 现有测试参考 | `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift` |

---

## Task 1：写失败测试 — plan 代理文件存在性与 frontmatter 基本解析

**目标：** 验证 `plan.agent.md` 存在、frontmatter 被正确解析，以及 `AgentRuntimeDefinition.make(from:)` 对其的 artifact 映射。

**Files:**
- Create: `agentGuiTests/PlanAgentDefinitionTests.swift`

**Step 1: 写失败测试**

```swift
import XCTest
@testable import agentGui

final class PlanAgentDefinitionTests: XCTestCase {

    // MARK: - plan.agent.md 文件加载

    func test_planAgentIsLoadedByBuiltInLoader() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        XCTAssertTrue(docs.contains(where: { $0.name == "plan" }),
                      "built-in agents 必须包含 plan 代理")
    }

    func test_planAgentFrontmatterFields() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))

        XCTAssertEqual(doc.displayName,      "架构规划者")
        XCTAssertEqual(doc.outputContract,   "plan_report")
        XCTAssertEqual(doc.modelPreference,  .inherit,
                       "plan 代理应继承主代理模型（full capability）")
        XCTAssertTrue(doc.omitMainContext,   "plan 代理应跳过主代理上下文注入")
        XCTAssertFalse(doc.userInvocable,   "plan 代理不应由用户直接调用")
        XCTAssertTrue(doc.subagentInvocable,"plan 代理应可由子代理调用")
        // tools 至少包含 read_only_editor
        XCTAssertTrue(doc.toolGroupNames.contains("read_only_editor"))
        // 不应包含写入工具组
        XCTAssertFalse(doc.toolGroupNames.contains("read_write_editor"))
        XCTAssertFalse(doc.toolGroupNames.contains("shell"))
        // body 不为空
        XCTAssertFalse(doc.body.isEmpty)
    }

    // MARK: - AgentRuntimeDefinition.make 对 plan 的 artifact 绑定

    func test_planRuntimeDefinitionArtifacts() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        // plan 代理可以读取 explorationReport
        XCTAssertTrue(runtime.readableArtifacts.contains(.explorationReport))
        // plan 代理产出 .plan 工产物
        XCTAssertTrue(runtime.writableArtifacts.contains(.plan))
        XCTAssertEqual(runtime.primaryOutputArtifactKind, .plan)
    }

    func test_planRuntimeDefinitionToolGrants_noWriteAccess() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        let hasWrite = runtime.toolGrants.contains {
            $0.toolGroupID == .readWriteEditor || $0.toolGroupID == .shell
        }
        XCTAssertFalse(hasWrite, "plan 代理不应有写文件或 shell 权限")
    }

    // MARK: - 现有三个代理不受影响（回归）

    func test_existingAgentsUnaffected() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let names = docs.map(\.name)
        XCTAssertTrue(names.contains("explore"))
        XCTAssertTrue(names.contains("worker"))
        XCTAssertTrue(names.contains("verifier"))
        // 共计 4 个内置代理
        XCTAssertEqual(names.filter { ["explore","worker","verifier","plan"].contains($0) }.count, 4)
    }

    // MARK: - WorkflowRoleDefinition 字段传播

    func test_planWorkflowRoleDefinition_propagatesOmitMainContext() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role = runtime.workflowRoleDefinition

        XCTAssertTrue(role.omitMainContext)
        XCTAssertEqual(role.modelPreference, .inherit)
        XCTAssertEqual(role.primaryOutputArtifactKind, .plan)
    }

    // MARK: - AgentCatalog 发现

    func test_agentCatalogFindsplan() throws {
        XCTAssertNotNil(AgentCatalog.shared.find(named: "plan"),
                        "AgentCatalog.shared 必须能按名称找到 plan 代理")
    }

    func test_agentCatalog_subagentInvocableIncludes_plan() throws {
        let names = AgentCatalog.shared.subagentInvocableAgents.map(\.name)
        XCTAssertTrue(names.contains("plan"))
    }

    // MARK: - 系统提示内包含关键约束文本

    func test_planSystemPromptContainsReadOnlyWarning() throws {
        let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
        let doc = try XCTUnwrap(docs.first(where: { $0.name == "plan" }))

        let prompt = doc.body.lowercased()
        // 必须含只读约束声明
        XCTAssertTrue(prompt.contains("read-only") || prompt.contains("read only"),
                      "plan 代理 body 必须包含 READ-ONLY 声明")
        // 必须含 critical files 输出要求
        XCTAssertTrue(prompt.contains("critical files"),
                      "plan 代理 body 必须要求输出 Critical Files for Implementation")
    }
}
```

**Step 2: 运行测试确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task1 \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：所有测试 **FAIL**（plan 文件不存在）

**Step 3: Commit 测试文件**

```bash
git add agentGuiTests/PlanAgentDefinitionTests.swift
git commit -m "test(S-B1): add PlanAgentDefinitionTests (red)"
```

---

## Task 2：创建 plan.agent.md 内置代理文件

**目标：** 创建符合设计要求的 `plan.agent.md` 文件，能被 `AgentDefinitionLoader` 正确解析。

**Files:**
- Create: `agentGui/Resources/Agents/plan.agent.md`

**Step 1: 创建文件**

```markdown
---
name: plan
display-name: 架构规划者
description: 只读探索代码库，生成分步骤实施方案。不修改任何文件。
argument-hint: Describe the requirements and architectural constraints to consider.
tools: [read_only_editor, web]
max-turns: 50
user-invocable: false
subagent-invocable: true
output-contract: plan_report
model-preference: inherit
omit-main-context: true
---

# Role

You are a software architect and planning specialist. Your role is to explore the codebase and design implementation plans.

## CRITICAL: READ-ONLY MODE — NO FILE MODIFICATIONS

You are STRICTLY PROHIBITED from:
- Creating new files (no Write, touch, or any file creation)
- Modifying existing files (no Edit operations)
- Deleting or moving files (no rm, mv, cp)
- Creating temporary files, including under `/tmp`
- Using shell redirects (`>`, `>>`) or heredocs to write to files
- Running ANY command that changes system state

Your role is EXCLUSIVELY to explore the codebase and design implementation plans. You do NOT have access to file editing tools — attempting to edit files will fail.

## Your Process

1. **Understand Requirements**: Focus on the requirements provided. Apply your architectural perspective throughout the design process.

2. **Explore Thoroughly**:
   - Read any files provided to you in the initial prompt.
   - Find existing patterns and conventions using search and file-read tools.
   - Understand the current architecture.
   - Identify similar features as reference.
   - Trace through relevant code paths.
   - **Batch independent reads and searches into parallel calls** — this is critical for speed.

3. **Design Solution**:
   - Create an implementation approach based on your assessment.
   - Consider trade-offs and architectural decisions.
   - Follow existing patterns where appropriate.

4. **Detail the Plan**:
   - Provide step-by-step implementation strategy.
   - Identify dependencies and sequencing.
   - Anticipate potential challenges.

## Output

End your response with:

### Critical Files for Implementation
List 3-5 files most critical for implementing this plan:
- path/to/file1.swift
- path/to/file2.swift

REMEMBER: You can ONLY explore and plan. You CANNOT and MUST NOT write, edit, or modify any files.
```

**注意：** 此文件必须通过 Xcode GUI 被加入 build target，否则 bundle 中不存在该文件。具体操作：
1. 在 Xcode Project Navigator 中右键 `agentGui/Resources/Agents/` → Add Files。
2. 确认 Target Membership 勾选 `agentGui`（主 target）。

**Step 2: 运行 Task 1 测试观察哪些通过、哪些仍失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task2 \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40
```

预期：除 artifact 相关测试（`test_planRuntimeDefinitionArtifacts`，`test_planRuntimeDefinitionToolGrants_noWriteAccess`）外均应 **PASS**；artifact 测试仍 FAIL（需要 Task 3 的代码改动）。

**Step 3: Commit**

```bash
git add agentGui/Resources/Agents/plan.agent.md agentGui.xcodeproj/project.pbxproj
git commit -m "feat(S-B1): add plan.agent.md built-in agent resource file"
```

---

## Task 3：在 AgentRuntimeDefinition.make(from:) 添加 "plan" 分支

**目标：** 为 `plan` 代理配置正确的 artifact 契约和通信契约，使其产出 `.plan` 工产物、可读 `.explorationReport`。

**Files:**
- Modify: `agentGui/Models/AgentRuntimeDefinition.swift`

**Step 1: 读文件找到插入点**

打开 `agentGui/Models/AgentRuntimeDefinition.swift`，在 `static func make(from document: AgentDefinitionDocument) throws -> AgentRuntimeDefinition` 中找到 `switch document.name` 语句。当前结构：

```swift
switch document.name {
case "explore":
    // ... explore 分支
case "worker":
    // ... worker 分支
case "verifier":
    // ... verifier 分支
default:
    // ... 通用回退
}
```

**Step 2: 在 `case "verifier":` 分支之后、`default:` 之前插入**

```swift
        case "plan":
            return AgentRuntimeDefinition(
                name: document.name,
                displayName: document.displayName,
                description: document.description,
                argumentHint: document.argumentHint,
                systemPrompt: document.body,
                toolGrants: toolGrants,
                maxTurns: document.maxTurns,
                userInvocable: document.userInvocable,
                subagentInvocable: document.subagentInvocable,
                outputContract: document.outputContract,
                readableArtifacts: [.explorationReport],
                writableArtifacts: [.plan],
                subscribesTo: [.task],
                defaultOutputMessageKind: .statusUpdate,
                primaryOutputArtifactKind: .plan,
                maxActivations: 3,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames,
                isOneShot: document.isOneShot
            )
```

**Step 3: 运行测试，所有应通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task3 \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|error:" | head -30
```

预期：全部 **PASS**。

**Step 4: Commit**

```bash
git add agentGui/Models/AgentRuntimeDefinition.swift
git commit -m "feat(S-B1): add plan branch to AgentRuntimeDefinition.make(from:)"
```

---

## Task 4：回归测试 — 现有内置代理定义加载不受干扰

**目标：** 确认 plan 分支插入后，explore/worker/verifier 原有 artifact 绑定未变，且 `AgentDefinitionLoaderOpenAgentTests` 全量通过。

**Files:**
- Test: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift`（不修改，仅执行）

**Step 1: 运行现有加载器测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task4 \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|error:" | head -30
```

预期：全部 **PASS**（与插入 plan 分支前相同）。

若有回归，检查 `AgentRuntimeDefinition.make(from:)` 是否误改了 `default:` 分支，或影响排序逻辑。

**Step 2: 若全量通过，无需额外 commit**

---

## Task 5：扩展 AgentDefinitionLoader.builtInSortOrder 包含 "plan"

**目标：** 保证 plan 代理在 `all` 列表中跟在 explore/worker/verifier 之后以固定顺序出现，不受文件系统字母排序影响。

**Files:**
- Modify: `agentGui/Services/AgentDefinitionLoader.swift`（仅修改 `builtInSortOrder` 数组）

**Step 1: 找到当前排序列表**

```swift
private static let builtInSortOrder = ["explore", "worker", "verifier"]
```

**Step 2: 修改为**

```swift
private static let builtInSortOrder = ["explore", "worker", "verifier", "plan"]
```

**Step 3: 添加排序顺序测试到 PlanAgentDefinitionTests**

在 `PlanAgentDefinitionTests.swift` 中追加：

```swift
// MARK: - 排序稳定性

func test_planAgentIsLastInBuiltInSortOrder() throws {
    let docs = try AgentDefinitionLoader().loadBuiltInDocuments(from: .main)
    let names = docs.map(\.name)
    // explore worker verifier plan 的相对顺序应稳定
    let exploreIdx  = try XCTUnwrap(names.firstIndex(of: "explore"))
    let workerIdx   = try XCTUnwrap(names.firstIndex(of: "worker"))
    let verifierIdx = try XCTUnwrap(names.firstIndex(of: "verifier"))
    let planIdx     = try XCTUnwrap(names.firstIndex(of: "plan"))

    XCTAssertLessThan(exploreIdx,  workerIdx)
    XCTAssertLessThan(workerIdx,   verifierIdx)
    XCTAssertLessThan(verifierIdx, planIdx)
}
```

**Step 4: 运行全量 PlanAgentDefinitionTests**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task5 \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|error:" | head -30
```

预期：全部 **PASS**。

**Step 5: Commit**

```bash
git add agentGui/Services/AgentDefinitionLoader.swift agentGuiTests/PlanAgentDefinitionTests.swift
git commit -m "feat(S-B1): add plan to builtInSortOrder; add sort order test"
```

---

## Task 6：WorkflowRoleDefinition 内置静态属性补全

**目标：** `WorkflowRoleDefinition` 中有 `static var planner` 别名当前指向 `explore`；将其更新为指向真正的 `plan` 代理，并补充 `static var plan` 便捷属性。同时更新 `all` 和 `find(named:)` 的说明注释。

**Files:**
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`

**Step 1: 找到当前静态别名区**

```swift
static var planner: WorkflowRoleDefinition { explore }
```

**Step 2: 添加 `plan` 便捷属性，并将 `planner` 改为指向它**

```swift
static var plan: WorkflowRoleDefinition {
    AgentCatalog.shared.find(named: "plan")!.workflowRoleDefinition
}

static var planner: WorkflowRoleDefinition { plan }
```

**Step 3: 写针对性测试（追加到 PlanAgentDefinitionTests）**

```swift
// MARK: - WorkflowRoleDefinition 静态属性

func test_workflowRoleDefinition_planStaticProperty() {
    let role = WorkflowRoleDefinition.plan
    XCTAssertEqual(role.name, "plan")
    XCTAssertEqual(role.primaryOutputArtifactKind, .plan)
}

func test_workflowRoleDefinition_plannerAliasPoinsToPlan() {
    XCTAssertEqual(WorkflowRoleDefinition.planner.name, "plan")
}
```

**Step 4: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-task6 \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|PASS|FAIL|error:" | head -20
```

预期：全部 **PASS**。

**Step 5: Commit**

```bash
git add agentGui/Models/WorkflowRoleDefinition.swift agentGuiTests/PlanAgentDefinitionTests.swift
git commit -m "feat(S-B1): add WorkflowRoleDefinition.plan static property; fix planner alias"
```

---

## Task 7：最终全量回归验证

**目标：** 确认 S-B1 全部改动不破坏现有测试套件。

**Step 1: 运行完整 built-in agent 相关测试套件**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-b1-regression \
  -only-testing:agentGuiTests/PlanAgentDefinitionTests \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -only-testing:agentGuiTests/SubagentModelResolverTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Suite|Passed|Failed|error:" | head -20
```

预期：全部通过，0 failures。

**Step 2: 最终提交 tag（可选）**

```bash
git tag s-b1-complete
```

---

## 实现摘要

| Task | 已改动文件 | 核心变化 |
|------|-----------|---------|
| 1 | `agentGuiTests/PlanAgentDefinitionTests.swift`（新建）| 红测试 |
| 2 | `agentGui/Resources/Agents/plan.agent.md`（新建），`project.pbxproj` | 代理定义资源文件 |
| 3 | `agentGui/Models/AgentRuntimeDefinition.swift` | `"plan"` switch 分支，artifact 绑定 |
| 4 | 无（回归运行既有测试） | — |
| 5 | `agentGui/Services/AgentDefinitionLoader.swift`，测试补充 | `builtInSortOrder` 排序 |
| 6 | `agentGui/Models/WorkflowRoleDefinition.swift`，测试补充 | `plan` 静态属性 + `planner` 别名修正 |
| 7 | 无（回归验证） | — |

**scope 边界（不属于 S-B1）：**
- `omitMainContext` 在系统提示构建中的实际过滤逻辑 → 属于 **S-A4**，应单独处理。
- `run_subagent` 工具的 agent_name 白名单放开 → 属于 **S-A1**，已完成。
- plan 代理与 PlanMode（`EnterPlanModeTool` / `ExitPlanModeTool`）的运行时协作协议 → 属于 **F-D1~D5**，不在此范围内。
- S-C2 后台执行、S-E1 生命周期钩子 → 属于后续 P1 task，不需要本 task 提前实现。

---

## 验收标准复查

| 验收项 | 覆盖 Task |
|--------|---------|
| plan 代理 `tools` schema 中不出现 `bash_write`、`file_write`（功能层面：只包含 read_only_editor、web） | Task 1：`test_planRuntimeDefinitionToolGrants_noWriteAccess` |
| plan 代理的 `omit-main-context: true` 正确传播到 `WorkflowRoleDefinition.omitMainContext` | Task 1：`test_planWorkflowRoleDefinition_propagatesOmitMainContext` |
| 名称不在旧白名单中时可正常加载（回归，S-A1 覆盖）| Task 4 回归 |
| 旧的 explore/worker/verifier 文件行为不变 | Task 4 回归 |
| `AgentCatalog.shared.find(named: "plan")` 返回非 nil | Task 1：`test_agentCatalogFindsplan` |
