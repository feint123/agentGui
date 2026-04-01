# S-A1: 开放代理定义体系 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 移除 `AgentDefinitionLoader` 中的 `allowedNames` / `allowedOutputContracts` 白名单硬编码限制，扩展 `AgentDefinitionDocument` / `WorkflowRoleDefinition` 支持 8 个新可选 frontmatter 字段，并保持对现有 3 个代理文件的向后兼容。

**Architecture:** 分 5 步渐进扩展：(1) 新增类型枚举；(2) 扩展 Document 结构体；(3) 改造 Loader 移除白名单并解析新字段；(4) 扩展 AgentRuntimeDefinition 添加通用 default 分支；(5) 扩展 WorkflowRoleDefinition 透传新字段。每一步都先写失败测试，再实现，再验证。

**Tech Stack:** Swift 6, SwiftData, XCTest，现有 `AgentDefinitionLoader` / `AgentRuntimeDefinition` / `WorkflowRoleDefinition` / `AgentCatalog` 架构。

**Test command:**
```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## 背景

### 当前锁定点（攻克目标）

**锁定点 1：** `AgentDefinitionLoader.allowedNames = ["explore", "worker", "verifier"]`
→ `parseDocument` 第 63 行：`guard ... allowedNames.contains(name) else { throw .invalidAgentName(...) }`

**锁定点 2：** `AgentDefinitionLoader.allowedOutputContracts = ["exploration_report", "work_result", "verification_report"]`
→ `parseDocument` 第 79 行：`guard ... allowedOutputContracts.contains(outputContract) else { throw .invalidOutputContract(...) }`

**锁定点 3：** `AgentRuntimeDefinition.make(from:)` 的 `default: throw AgentValidationError.invalidAgentName(document.name)`
→ 就算 Loader 放行了新名称，到 `make` 还是会抛异常

**锁定点 4：** `AgentDefinitionLoader.optionalFields` 未包含新字段
→ `unsupportedFields` 检查会拒绝新 frontmatter 字段

### 新增可选 frontmatter 字段

| frontmatter key      | Swift 字段名          | 类型                        | 缺省值      |
|----------------------|-----------------------|-----------------------------|-------------|
| `model-preference`   | `modelPreference`     | `SubagentModelPreference`   | `.inherit`  |
| `effort`             | `effort`              | `SubagentEffort?`           | `nil`       |
| `background`         | `background`          | `Bool`                      | `false`     |
| `omit-main-context`  | `omitMainContext`     | `Bool`                      | `false`     |
| `initial-prompt`     | `initialPrompt`       | `String?`                   | `nil`       |
| `critical-reminder`  | `criticalReminder`    | `String?`                   | `nil`       |
| `color`              | `color`               | `String?`                   | `nil`       |
| `disallowed-tools`   | `disallowedToolNames` | `[String]`                  | `[]`        |

---

## Task 1: 新增 `SubagentModelPreference` 和 `SubagentEffort` 枚举

**Files:**
- Create: `agentGui/Models/SubagentExecutionTraits.swift`
- Test: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift` (部分)

### Step 1: 新建测试文件，写最小占位测试

```swift
// agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
import XCTest
@testable import agentGui

final class AgentDefinitionLoaderOpenAgentTests: XCTestCase {

    // MARK: - SubagentModelPreference

    func test_modelPreference_rawValueRoundTrip() {
        XCTAssertEqual(SubagentModelPreference(rawValue: "haiku"),  .haiku)
        XCTAssertEqual(SubagentModelPreference(rawValue: "sonnet"), .sonnet)
        XCTAssertEqual(SubagentModelPreference(rawValue: "opus"),   .opus)
        XCTAssertEqual(SubagentModelPreference(rawValue: "inherit"),.inherit)
        XCTAssertNil(SubagentModelPreference(rawValue: "unknown"))
    }

    func test_effort_rawValueRoundTrip() {
        XCTAssertEqual(SubagentEffort(rawValue: "low"),    .low)
        XCTAssertEqual(SubagentEffort(rawValue: "medium"), .medium)
        XCTAssertEqual(SubagentEffort(rawValue: "high"),   .high)
        XCTAssertNil(SubagentEffort(rawValue: "critical"))
    }
}
```

### Step 2: 运行测试，确认编译失败（类型不存在）

```bash
# 期望：Build FAILED — Cannot find type 'SubagentModelPreference'
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests/test_modelPreference_rawValueRoundTrip \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Build FAILED"
```

### Step 3: 创建 `SubagentExecutionTraits.swift`

```swift
// agentGui/Models/SubagentExecutionTraits.swift
import Foundation

/// 子代理使用的模型偏好。
/// - `inherit`：沿用父代理当前模型（默认）
/// - `haiku`：claude-haiku 系列（快速、低成本，适合探索）
/// - `sonnet`：claude-sonnet 系列（均衡）
/// - `opus`：claude-opus 系列（高能力，适合验证/执行）
enum SubagentModelPreference: String, Sendable, Codable, Equatable {
    case inherit
    case haiku
    case sonnet
    case opus
}

/// 子代理 thinking budget 偏好。
enum SubagentEffort: String, Sendable, Codable, Equatable {
    case low
    case medium
    case high
}
```

> **注意：** 这两个枚举都需要加入 Xcode target（agentGui）和 agentGuiTests target 均可编译。确认文件的 Target Membership 包含 agentGui。

### Step 4: 运行测试，确认通过

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests/test_modelPreference_rawValueRoundTrip \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests/test_effort_rawValueRoundTrip \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：Test Suite ... passed at ...  Executed 2 tests, with 0 failures
```

### Step 5: Commit

```
git add agentGui/Models/SubagentExecutionTraits.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "s-a1: add SubagentModelPreference and SubagentEffort enums"
```

---

## Task 2: 扩展 `AgentDefinitionDocument` 新增 8 个可选字段

**Files:**
- Modify: `agentGui/Models/AgentDefinitionDocument.swift`

### Step 1: 在测试文件追加 `make` helper 和字段断言

把以下内容加到 `AgentDefinitionLoaderOpenAgentTests.swift` 末尾（在类关闭花括号之前）：

```swift
    // MARK: - AgentDefinitionDocument optional fields

    private let minimalFrontmatter = """
        ---
        name: researcher
        display-name: Research Agent
        description: Searches and summarises.
        argument-hint: Describe what to find.
        tools: [read_only_editor]
        max-turns: 20
        user-invocable: false
        subagent-invocable: true
        output-contract: research_report
        ---
        # Role
        You are a researcher.
        """

    func test_documentDefaultsForOptionalFields() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)

        XCTAssertEqual(doc.modelPreference,    .inherit)
        XCTAssertNil(doc.effort)
        XCTAssertFalse(doc.background)
        XCTAssertFalse(doc.omitMainContext)
        XCTAssertNil(doc.initialPrompt)
        XCTAssertNil(doc.criticalReminder)
        XCTAssertNil(doc.color)
        XCTAssertEqual(doc.disallowedToolNames, [])
    }

    func test_documentParsesAllOptionalFields() throws {
        let raw = """
            ---
            name: analyst
            display-name: Analyst
            description: Deep analysis.
            argument-hint: Topic to analyse.
            tools: [read_only_editor]
            max-turns: 10
            user-invocable: false
            subagent-invocable: true
            output-contract: analysis_report
            model-preference: haiku
            effort: high
            background: true
            omit-main-context: true
            initial-prompt: Think carefully before answering.
            critical-reminder: READ-ONLY. Do not edit files.
            color: blue
            disallowed-tools: [bash_write, file_delete]
            ---
            # Role
            You are an analyst.
            """
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "analyst.agent.md", raw: raw)

        XCTAssertEqual(doc.modelPreference,      .haiku)
        XCTAssertEqual(doc.effort,               .high)
        XCTAssertTrue(doc.background)
        XCTAssertTrue(doc.omitMainContext)
        XCTAssertEqual(doc.initialPrompt,        "Think carefully before answering.")
        XCTAssertEqual(doc.criticalReminder,     "READ-ONLY. Do not edit files.")
        XCTAssertEqual(doc.color,                "blue")
        XCTAssertEqual(doc.disallowedToolNames,  ["bash_write", "file_delete"])
    }
```

### Step 2: 运行测试，确认编译失败（字段不存在）

```bash
# 期望：Build FAILED — value of type 'AgentDefinitionDocument' has no member 'modelPreference'
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
```

### Step 3: 扩展 `AgentDefinitionDocument`

完整替换 `agentGui/Models/AgentDefinitionDocument.swift` 内容：

```swift
import Foundation

struct AgentDefinitionDocument: Sendable, Equatable {

    // MARK: - Required fields (同原有字段，不变)
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let toolGroupNames: [String]
    let maxTurns: Int
    let userInvocable: Bool
    let subagentInvocable: Bool
    let outputContract: String
    let body: String

    // MARK: - Optional execution-trait fields (S-A1 新增)
    let modelPreference: SubagentModelPreference   // default: .inherit
    let effort: SubagentEffort?                    // default: nil
    let background: Bool                           // default: false
    let omitMainContext: Bool                      // default: false
    let initialPrompt: String?                     // default: nil
    let criticalReminder: String?                  // default: nil
    let color: String?                             // default: nil
    let disallowedToolNames: [String]              // default: []
}
```

### Step 4: 修复所有初始化调用

现在 `AgentDefinitionDocument` 的 memberwise init 多了 8 个字段，所有调用它的地方都会报错。主要是 `AgentDefinitionLoader.parseDocument` 中的 return 语句。

把 `AgentDefinitionLoader.parseDocument` 末尾的 `return AgentDefinitionDocument(...)` 替换为：

```swift
        return AgentDefinitionDocument(
            name: name,
            displayName: displayName,
            description: description,
            argumentHint: argumentHint,
            toolGroupNames: tools,
            maxTurns: maxTurns,
            userInvocable: userInvocable,
            subagentInvocable: subagentInvocable,
            outputContract: outputContract,
            body: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            modelPreference: .inherit,   // 暂时硬编码，Task 3 会改为真正解析
            effort: nil,
            background: false,
            omitMainContext: false,
            initialPrompt: nil,
            criticalReminder: nil,
            color: nil,
            disallowedToolNames: []
        )
```

### Step 5: 运行测试，确认构建通过但字段测试失败（因为还没解析）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case|error:|FAILED|passed"
# 期望：test_documentDefaultsForOptionalFields → FAIL (loader 还在 Task 3 前)
#       test_documentParsesAllOptionalFields  → FAIL
# 同时：现有的 explore/worker/verifier 如果有覆盖测试，仍应通过（不破坏）
```

> 如果此时 test_documentDefaultsForOptionalFields **通过**（因为 .agent.md 恰好没有这些字段，且临时硬编码与默认值一致），那仍可继续 Task 3。

### Step 6: Commit

```
git add agentGui/Models/AgentDefinitionDocument.swift
git commit -m "s-a1: extend AgentDefinitionDocument with 8 optional execution-trait fields (stub values)"
```

---

## Task 3: 扩展 `AgentDefinitionLoader` — 移除白名单 + 解析新字段

**Files:**
- Modify: `agentGui/Services/AgentDefinitionLoader.swift`

### Step 1: 在测试文件追加白名单锁定和新字段解析测试

```swift
    // MARK: - Whitelist removal

    func test_customAgentNameLoadsSuccessfully() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)
        XCTAssertEqual(doc.name, "researcher")
    }

    func test_customOutputContractLoadsSuccessfully() throws {
        let raw = minimalFrontmatter  // output-contract: research_report (非白名单)
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: raw)
        XCTAssertEqual(doc.outputContract, "research_report")
    }

    func test_existingExploreAgentStillLoads() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        XCTAssertTrue(docs.contains(where: { $0.name == "explore" }))
        XCTAssertTrue(docs.contains(where: { $0.name == "worker" }))
        XCTAssertTrue(docs.contains(where: { $0.name == "verifier" }))
    }

    func test_modelPreferenceField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: scout
            display-name: Scout
            description: Scout agent.
            argument-hint: Where to scout.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: scout_report
            model-preference: haiku
            ---
            # Role
            Scout.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "scout.agent.md", raw: raw)
        XCTAssertEqual(doc.modelPreference, .haiku)
    }

    func test_backgroundField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: bg-worker
            display-name: Background Worker
            description: Runs in background.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: bg_result
            background: true
            ---
            # Role
            Background.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "bg-worker.agent.md", raw: raw)
        XCTAssertTrue(doc.background)
    }

    func test_disallowedToolsField_parsedFromFrontmatter() throws {
        let raw = """
            ---
            name: safe-scout
            display-name: Safe Scout
            description: Read-only scout.
            argument-hint: What to find.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: scout_report
            disallowed-tools: [bash_exec, file_write]
            ---
            # Role
            Safe.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "safe-scout.agent.md", raw: raw)
        XCTAssertEqual(doc.disallowedToolNames, ["bash_exec", "file_write"])
    }
```

### Step 2: 运行测试，确认现有测试失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:"
# 期望：test_customAgentNameLoadsSuccessfully → FAIL (invalidAgentName thrown)
#       test_customOutputContractLoadsSuccessfully → FAIL (invalidOutputContract thrown)
#       test_modelPreferenceField_parsedFromFrontmatter → FAIL (unsupportedFields)
```

### Step 3: 改造 `AgentDefinitionLoader.swift`

**3a. 删除 `allowedNames` 和 `allowedOutputContracts` 属性**（找到这两行并删除）：

```swift
// 删除这两行：
private let allowedNames = ["explore", "worker", "verifier"]
private let allowedOutputContracts: Set<String> = ["exploration_report", "work_result", "verification_report"]
```

**3b. 扩展 `optionalFields`**，把新字段加进去：

```swift
// 替换原有 optionalFields = [...]
private let optionalFields: Set<String> = [
    "model-preference",
    "effort",
    "background",
    "omit-main-context",
    "initial-prompt",
    "critical-reminder",
    "color",
    "disallowed-tools",
    "tags",
    "examples",
    "notes"
]
```

**3c. 删除 `allowedNames` 白名单 guard**

找到并删除以下代码块（约在 `parseDocument` 函数中）：

```swift
// 删除这行 guard：
guard let name = parsed.fields["name"], allowedNames.contains(name) else {
    throw AgentValidationError.invalidAgentName(parsed.fields["name"] ?? named)
}
```

替换为：

```swift
guard let name = parsed.fields["name"], !name.isEmpty else {
    throw AgentValidationError.missingRequiredField("name")
}
```

**3d. 删除 `allowedOutputContracts` 白名单 guard**

找到并删除：

```swift
// 删除这行 guard：
guard let outputContract = parsed.fields["output-contract"], allowedOutputContracts.contains(outputContract) else {
    throw AgentValidationError.invalidOutputContract(parsed.fields["output-contract"] ?? "")
}
```

替换为：

```swift
guard let outputContract = parsed.fields["output-contract"],
      !outputContract.isEmpty else {
    throw AgentValidationError.missingRequiredField("output-contract")
}
```

**3e. 在 return 语句前添加新字段解析**（就在最终 `return AgentDefinitionDocument(...)` 之前）：

```swift
        // MARK: Optional execution-trait fields (S-A1)
        let modelPreference = parsed.fields["model-preference"]
            .flatMap(SubagentModelPreference.init(rawValue:)) ?? .inherit

        let effort = parsed.fields["effort"]
            .flatMap(SubagentEffort.init(rawValue:))

        let background = parseBool(parsed.fields["background"] ?? "false") ?? false

        let omitMainContext = parseBool(parsed.fields["omit-main-context"] ?? "false") ?? false

        let initialPrompt = parsed.fields["initial-prompt"].flatMap { $0.isEmpty ? nil : $0 }

        let criticalReminder = parsed.fields["critical-reminder"].flatMap { $0.isEmpty ? nil : $0 }

        let color = parsed.fields["color"].flatMap { $0.isEmpty ? nil : $0 }

        let disallowedToolNames: [String]
        if let rawDisallowed = parsed.fields["disallowed-tools"] {
            disallowedToolNames = try parseArray(rawDisallowed)
        } else {
            disallowedToolNames = []
        }
```

**3f. 更新最终的 `return AgentDefinitionDocument(...)` 调用**，传入所有新字段：

```swift
        return AgentDefinitionDocument(
            name: name,
            displayName: displayName,
            description: description,
            argumentHint: argumentHint,
            toolGroupNames: tools,
            maxTurns: maxTurns,
            userInvocable: userInvocable,
            subagentInvocable: subagentInvocable,
            outputContract: outputContract,
            body: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            modelPreference: modelPreference,
            effort: effort,
            background: background,
            omitMainContext: omitMainContext,
            initialPrompt: initialPrompt,
            criticalReminder: criticalReminder,
            color: color,
            disallowedToolNames: disallowedToolNames
        )
```

**3g. 更新 `sortIndex(for:)` 方法**（因为 `allowedNames` 被删除了）：

```swift
// 原来：
private func sortIndex(for name: String) -> Int {
    allowedNames.firstIndex(of: name) ?? .max
}

// 替换为：
private static let builtInSortOrder = ["explore", "worker", "verifier"]

private func sortIndex(for name: String) -> Int {
    Self.builtInSortOrder.firstIndex(of: name) ?? .max
}
```

### Step 4: 运行所有 S-A1 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
# 期望：Executed N tests, with 0 failures
```

> **如果 test_existingExploreAgentStillLoads 失败：** 检查是否因 `AgentRuntimeDefinition.make` 仍然对旧名字有 `throw default`。Task 4 将修复此问题。目前先确认 Loader 层的测试通过，再进行 Task 4。

### Step 5: Commit

```
git add agentGui/Services/AgentDefinitionLoader.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "s-a1: remove allowedNames/allowedOutputContracts whitelists, parse new optional frontmatter fields"
```

---

## Task 4: 扩展 `AgentRuntimeDefinition` — 新字段 + 通用 default 分支

**Files:**
- Modify: `agentGui/Models/AgentRuntimeDefinition.swift`

### Step 1: 在测试文件追加 RuntimeDefinition 测试

```swift
    // MARK: - AgentRuntimeDefinition generic default

    func test_customAgentMakesRuntimeDefinitionWithDefaultArtifacts() throws {
        let loader = AgentDefinitionLoader()
        let doc = try loader.parseDocument(named: "researcher.agent.md", raw: minimalFrontmatter)
        let runtime = try AgentRuntimeDefinition.make(from: doc)

        XCTAssertEqual(runtime.name, "researcher")
        XCTAssertEqual(runtime.outputContract, "research_report")
        XCTAssertEqual(runtime.readableArtifacts, [])
        XCTAssertEqual(runtime.writableArtifacts, [])
    }

    func test_customAgentRuntimeDefinitionPropagatesModelPreference() throws {
        let raw = """
            ---
            name: haiku-agent
            display-name: Haiku Agent
            description: Uses haiku model.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: haiku_report
            model-preference: haiku
            ---
            # Role
            Haiku.
            """
        let doc = try AgentDefinitionLoader().parseDocument(named: "haiku-agent.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        XCTAssertEqual(runtime.modelPreference, .haiku)
    }

    func test_existingExploreRuntimeDefinitionPreservesArtifacts() throws {
        let loader = AgentDefinitionLoader()
        let docs = try loader.loadBuiltInDocuments(from: .main)
        let exploreDoc = try XCTUnwrap(docs.first(where: { $0.name == "explore" }))
        let runtime = try AgentRuntimeDefinition.make(from: exploreDoc)

        XCTAssertEqual(runtime.readableArtifacts,  [.plan])
        XCTAssertEqual(runtime.writableArtifacts,  [.explorationReport])
        XCTAssertEqual(runtime.primaryOutputArtifactKind, .explorationReport)
    }
```

### Step 2: 运行测试，确认失败

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "FAILED|error:"
# 期望：test_customAgentMakesRuntimeDefinitionWithDefaultArtifacts → FAIL
#       (因为 default: throw AgentValidationError.invalidAgentName)
```

### Step 3: 修改 `AgentRuntimeDefinition.swift`

**3a. 在 struct 定义中新增 8 个字段**（在 `maxActivations` 后面追加）：

```swift
    let maxActivations: Int

    // MARK: - S-A1 Optional execution-trait fields
    let modelPreference: SubagentModelPreference  // default: .inherit
    let effort: SubagentEffort?
    let background: Bool
    let omitMainContext: Bool
    let initialPrompt: String?
    let criticalReminder: String?
    let color: String?
    let disallowedToolNames: [String]

    var workflowRoleDefinition: WorkflowRoleDefinition { ... }
```

**3b. 更新 3 个现有 case 的 init 调用**，在每个 case 的 `AgentRuntimeDefinition(...)` 最后追加新字段（所有 3 个 case 相同的追加方式）：

```swift
            // 在 explore/ worker/ verifier 三个 case 的 AgentRuntimeDefinition(...) 末尾各自追加：
                maxActivations: <原来的值>,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames
```

> 每个 case 要逐一修改，共 3 处。注意不要漏掉任何一个。

**3c. 将 `default: throw AgentValidationError.invalidAgentName(...)` 替换为通用 init**：

```swift
        default:
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
                readableArtifacts: [],
                writableArtifacts: [],
                subscribesTo: [.task],
                defaultOutputMessageKind: .statusUpdate,
                primaryOutputArtifactKind: nil,
                maxActivations: 5,
                modelPreference: document.modelPreference,
                effort: document.effort,
                background: document.background,
                omitMainContext: document.omitMainContext,
                initialPrompt: document.initialPrompt,
                criticalReminder: document.criticalReminder,
                color: document.color,
                disallowedToolNames: document.disallowedToolNames
            )
```

**3d. 更新 `workflowRoleDefinition` 计算属性**，把新字段转发到 `WorkflowRoleDefinition.init`（Task 5 会真正扩展 `WorkflowRoleDefinition`，这里先保持原逻辑，新字段暂不传入——等 Task 5 完成后再补充）。

### Step 4: 运行测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：Executed N tests, with 0 failures
```

### Step 5: Commit

```
git add agentGui/Models/AgentRuntimeDefinition.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "s-a1: AgentRuntimeDefinition generic default case + propagate execution-trait fields"
```

---

## Task 5: 扩展 `WorkflowRoleDefinition` 透传新字段

**Files:**
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`

### Step 1: 在测试文件追加 WorkflowRoleDefinition 字段断言

```swift
    // MARK: - WorkflowRoleDefinition field propagation

    func test_workflowRoleDefinitionPropagatesModelPreference() throws {
        let raw = """
            ---
            name: haiku-role
            display-name: Haiku Role
            description: Uses haiku.
            argument-hint: Task.
            tools: [read_only_editor]
            max-turns: 5
            user-invocable: false
            subagent-invocable: true
            output-contract: haiku_report
            model-preference: haiku
            ---
            # Role
            Haiku.
            """
        let doc  = try AgentDefinitionLoader().parseDocument(named: "haiku-role.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role = runtime.workflowRoleDefinition

        XCTAssertEqual(role.modelPreference, .haiku)
        XCTAssertFalse(role.omitMainContext)
        XCTAssertNil(role.criticalReminder)
        XCTAssertEqual(role.disallowedToolNames, [])
    }

    func test_workflowRoleDefinitionPropagatesOmitMainContext() throws {
        let raw = """
            ---
            name: lean-explorer
            display-name: Lean Explorer
            description: Lean explore.
            argument-hint: What to find.
            tools: [read_only_editor]
            max-turns: 10
            user-invocable: false
            subagent-invocable: true
            output-contract: exploration_result
            omit-main-context: true
            critical-reminder: READ ONLY. Do not write files.
            ---
            # Role
            Lean.
            """
        let doc  = try AgentDefinitionLoader().parseDocument(named: "lean-explorer.agent.md", raw: raw)
        let runtime = try AgentRuntimeDefinition.make(from: doc)
        let role = runtime.workflowRoleDefinition

        XCTAssertTrue(role.omitMainContext)
        XCTAssertEqual(role.criticalReminder, "READ ONLY. Do not write files.")
    }
```

### Step 2: 运行测试，确认失败（WorkflowRoleDefinition 无对应字段）

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:" | head -5
# 期望：Build FAILED — value of type 'WorkflowRoleDefinition' has no member 'modelPreference'
```

### Step 3: 扩展 `WorkflowRoleDefinition`

**3a. 在 `WorkflowRoleDefinition` struct 的 `// MARK: Activation Budget` 段落后面追加新属性**：

```swift
    // MARK: - S-A1 Execution Traits

    /// 子代理优先使用的模型。`.inherit` 表示沿用父代理的模型。
    let modelPreference: SubagentModelPreference

    /// Thinking budget 偏好（`nil` 表示使用服务默认值）。
    let effort: SubagentEffort?

    /// `true` 时此代理总应以后台任务方式产生（不阻塞父代理 loop）。
    let background: Bool

    /// `true` 时对此代理构建系统提示时跳过 CLAUDE.md 层级、git status
    /// 和 workspace 状态描述（节省只读代理的 token 开销）。
    let omitMainContext: Bool

    /// 子代理第一轮 user-message 前额外注入的文本（nil = 不注入）。
    let initialPrompt: String?

    /// 每轮 user-message 前重新注入的短提醒（≤200 字；nil = 不注入）。
    let criticalReminder: String?

    /// UI 标注颜色名称（nil = 使用默认）。
    let color: String?

    /// 从代理可用工具集中排除的工具名称列表（空 = 不排除）。
    let disallowedToolNames: [String]
```

**3b. 在 `init(...)` 参数列表末尾追加新参数（含默认值）**：

```swift
    init(
        name: String,
        displayName: String,
        description: String = "",
        systemPrompt: String,
        enableTextEditor: Bool = true,
        enableBash: Bool = false,
        enableWebSearch: Bool = false,
        enableWebFetch: Bool = false,
        toolGrants: [ToolGrant] = [],
        readableArtifacts: Set<WorkflowArtifactKind> = [],
        writableArtifacts: Set<WorkflowArtifactKind> = [],
        subscribesTo: Set<WorkflowMessageKind> = [.task],
        defaultOutputMessageKind: WorkflowMessageKind = .statusUpdate,
        primaryOutputArtifactKind: WorkflowArtifactKind? = nil,
        maxTurnsPerActivation: Int = 10,
        maxActivations: Int = 5,
        // S-A1 新增（全部有默认值，向后兼容）
        modelPreference: SubagentModelPreference = .inherit,
        effort: SubagentEffort? = nil,
        background: Bool = false,
        omitMainContext: Bool = false,
        initialPrompt: String? = nil,
        criticalReminder: String? = nil,
        color: String? = nil,
        disallowedToolNames: [String] = []
    ) {
        // 原有字段赋值...
        self.maxTurnsPerActivation = maxTurnsPerActivation
        self.maxActivations = maxActivations
        // 新字段赋值
        self.modelPreference = modelPreference
        self.effort = effort
        self.background = background
        self.omitMainContext = omitMainContext
        self.initialPrompt = initialPrompt
        self.criticalReminder = criticalReminder
        self.color = color
        self.disallowedToolNames = disallowedToolNames
    }
```

> 注意：由于所有新参数都有默认值，现有的所有 `WorkflowRoleDefinition(...)` 调用（包括测试）**无需修改**，向后兼容性自动保持。

**3c. 更新 `AgentRuntimeDefinition.workflowRoleDefinition` 计算属性**，把新字段传入：

在 `AgentRuntimeDefinition.swift` 的 `workflowRoleDefinition` 计算属性的 `WorkflowRoleDefinition(...)` 调用末尾追加：

```swift
        var workflowRoleDefinition: WorkflowRoleDefinition {
            WorkflowRoleDefinition(
                name: name,
                displayName: displayName,
                description: description,
                systemPrompt: systemPrompt,
                enableTextEditor: ...,
                // ... 原有字段 ...
                maxTurnsPerActivation: maxTurns,
                maxActivations: maxActivations,
                // S-A1 新增：
                modelPreference: modelPreference,
                effort: effort,
                background: background,
                omitMainContext: omitMainContext,
                initialPrompt: initialPrompt,
                criticalReminder: criticalReminder,
                color: color,
                disallowedToolNames: disallowedToolNames
            )
        }
```

### Step 4: 运行所有 S-A1 测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：Executed N tests, with 0 failures
```

### Step 5: Commit

```
git add agentGui/Models/WorkflowRoleDefinition.swift agentGui/Models/AgentRuntimeDefinition.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "s-a1: WorkflowRoleDefinition propagates execution-trait fields with default-value backward compat"
```

---

## Task 6: 验证向后兼容 + 全量回归

### Step 1: 运行 Quality Smoke（全量测试）

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-smoke \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

期望：所有现有测试通过，无回归。

### Step 2: 向后兼容手动检查清单

- [ ] `explore.agent.md` 无变化，加载后 `modelPreference == .inherit`、`omitMainContext == false`
- [ ] `worker.agent.md` 无变化，加载后 `disallowedToolNames == []`
- [ ] `verifier.agent.md` 无变化，加载后 `background == false`
- [ ] `AgentCatalog.shared` 仍能正确初始化（不 `fatalError`）
- [ ] `WorkflowRoleDefinition.find(named:)` 对 3 个旧名字正常返回

### Step 3: 追加向后兼容断言测试

```swift
    // MARK: - Backward compatibility

    func test_existingAgentsHaveDefaultOptionalFieldValues() throws {
        let catalog = AgentCatalog.shared
        let explore  = try XCTUnwrap(catalog.find(named: "explore"))
        let worker   = try XCTUnwrap(catalog.find(named: "worker"))
        let verifier = try XCTUnwrap(catalog.find(named: "verifier"))

        for runtime in [explore, worker, verifier] {
            XCTAssertEqual(runtime.modelPreference, .inherit,
                           "\(runtime.name) modelPreference should default to .inherit")
            XCTAssertNil(runtime.effort,
                         "\(runtime.name) effort should default to nil")
            XCTAssertFalse(runtime.background,
                           "\(runtime.name) background should default to false")
            XCTAssertFalse(runtime.omitMainContext,
                           "\(runtime.name) omitMainContext should default to false")
            XCTAssertNil(runtime.initialPrompt)
            XCTAssertNil(runtime.criticalReminder)
            XCTAssertNil(runtime.color)
            XCTAssertEqual(runtime.disallowedToolNames, [])
        }
    }
```

### Step 4: 运行最终回归测试

```bash
xcodebuild test \
  -project agentGui.xcodeproj -scheme agentGui \
  -destination "platform=macOS" -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-s-a1-derived \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
# 期望：Executed N tests, with 0 failures
```

### Step 5: Final Commit

```
git add agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "s-a1: backward-compat regression tests for existing explore/worker/verifier agents"
```

---

## 验收检查清单

完成所有 Task 后，逐项确认：

- [ ] **Task 1** `SubagentModelPreference` / `SubagentEffort` 存在于 `SubagentExecutionTraits.swift`，通过 rawValue 轮转测试
- [ ] **Task 2** `AgentDefinitionDocument` 有 8 个新字段（全部有默认初始化值）
- [ ] **Task 3** `AgentDefinitionLoader.allowedNames` 属性不存在；`allowedOutputContracts` 属性不存在；`optionalFields` 包含 8 个新 key；`researcher` / `analyst` 等自定义名称可解析
- [ ] **Task 4** `AgentRuntimeDefinition.make(from:)` 的 `default:` 不再 throw，而是返回带空 artifacts 的通用定义
- [ ] **Task 5** `WorkflowRoleDefinition` 有 8 个新字段，全部有默认值；现有所有调用站不需修改
- [ ] **Task 6** 全量测试通过，`explore/worker/verifier` 的行为与 S-A1 前完全相同

---

## 常见错误排查

| 错误 | 原因 | 解决 |
|------|------|------|
| `AgentCatalog` 在 `init` 时 `fatalError` | `AgentRuntimeDefinition.make` 中某个字段丢失，导致 struct 无法初始化 | 检查 3 个旧 case 是否都传了新字段 |
| `unsupportedFields: [model-preference]` | `optionalFields` 未更新 | 确认 Task 3b 已完成 |
| `Build FAILED: missing argument 'modelPreference'` | `WorkflowRoleDefinition.init` 参数未追加默认值参数 | Task 5b 的默认值参数是否完整 |
| 测试`test_existingExploreRuntimeDefinitionPreservesArtifacts` 失败 | 3 个旧 case 的 artifacts 被意外改动 | 确认只改动了 `default:` 分支 |
