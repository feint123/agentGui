# S-A2 One-Shot Agent Trailer Skip 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `WorkflowRoleDefinition` 新增 `isOneShot: Bool` 字段；对 `explore` 代理默认开启；在 `runSubagentLoop` 中为非 one-shot 代理追加执行元数据 trailer，为 one-shot 代理跳过 trailer，节省每次 explore 执行约 80 字符的 token 开销。

**Architecture:** 在现有的 `AgentDefinitionDocument` → `AgentRuntimeDefinition` → `WorkflowRoleDefinition` 三层结构中逐层透传 `isOneShot`（新增可选 frontmatter 字段 `one-shot: bool`）；修改 `runSubagentLoop` 的输出文本，根据此标记决定是否追加 `<agent_execution>` trailer 段；所有改动均无副作用，向后兼容（默认 `false`，即有 trailer）。

**Tech Stack:** Swift 6, SwiftAnthropic, `xcodebuild` on macOS.

**依赖:** S-A1（`AgentDefinitionDocument` 的可选字段解析体系已建立，本 Feature 沿用同一模式）。

---

## 背景与约束

### 当前状态（S-A2 开始前）

`runSubagentLoop` 返回的 `AgentMessage.content.apiString` 就是子代理的纯文本输出，没有额外 trailer：

```swift
// ClaudeService+Subagent.swift — 当前返回值
return .detecting(text: output, sender: definition.name, metadata: metadata)
```

`metadata`（`agent / rounds / elapsed`）仅存入 `ToolCall.subagentMessageMetadata`，**不会**注入父代理的对话上下文。

### 目标状态（S-A2 完成后）

- **非 one-shot 代理**（`worker`、`verifier`、自定义代理）：输出末尾追加 trailer：
  ```
  <agent_execution>agent: worker | rounds: 4 | elapsed: 12.34s</agent_execution>
  ```
  父代理可读取执行摘要，未来也可扩展为含 `agentId` 的异步续接信息（S-C1 阶段）。

- **One-shot 代理**（`explore`）：直接返回报告文本，不追加 trailer，节省约 80 字符 × 每次调用的 token。

### Trailer 格式规范

```
\n<agent_execution>agent: <name> | rounds: <N> | elapsed: <X.XXs></agent_execution>
```

约 70–80 字符，测试时通过字符串 `contains` 断言校验。

---

## 文件改动总览

**新增字段（Data Layer）：**
- Modify: `agentGui/Models/AgentDefinitionDocument.swift`
- Modify: `agentGui/Services/AgentDefinitionLoader.swift`
- Modify: `agentGui/Models/AgentRuntimeDefinition.swift`
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`

**执行逻辑：**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`

**代理定义文件：**
- Modify: `agentGui/Resources/Agents/explore.agent.md`

**测试：**
- Modify: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift`
- Create: `agentGuiTests/OneShotSubagentTrailerTests.swift`

---

## Task 1：给 AgentDefinitionDocument 新增 isOneShot 字段

**Files:**
- Modify: `agentGui/Models/AgentDefinitionDocument.swift`
- Modify: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift`

> 仅改数据模型，不涉及任何逻辑。此步完成后可独立编译通过。

**Step 1: 在 test 文件中写出预期断言（先让 test 指向不存在的字段，确认编译报错）**

在 `AgentDefinitionLoaderOpenAgentTests.swift` 的 `test_documentDefaultsForOptionalFields()` 末尾添加：

```swift
XCTAssertFalse(doc.isOneShot)
```

在 `test_documentParsesAllOptionalFields()` 的断言块末尾添加（先不加 frontmatter 字段，下一 Task 再加）：

```swift
XCTAssertFalse(doc.isOneShot)   // 未设置时默认 false
```

**Step 2: 运行测试，确认编译失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task1 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build FAILED"
```

预期：`error: value of type 'AgentDefinitionDocument' has no member 'isOneShot'`

**Step 3: 在 AgentDefinitionDocument.swift 中新增字段**

在 `// MARK: - Optional execution-trait fields (S-A1)` 段的最后一行（`let disallowedToolNames: [String]`）之后添加：

```swift
    // MARK: - S-A2 One-Shot
    /// `true` 时子代理执行完成后不附加执行元数据 trailer，节省 token。
    let isOneShot: Bool                        // frontmatter: one-shot (default: false)
```

**Step 4: 运行测试，确认编译通过但测试失败（isOneShot 无初始化值）**

此时 `AgentDefinitionDocument` 的 `init` 缺少 `isOneShot` 参数，编译将再次报错。在 Step 3 之前先不改 `init`，确认字段声明已被识别即可；然后在 `AgentDefinitionDocument` 的 `init` 中补充 `isOneShot: Bool` 参数（默认 `false`）。

`AgentDefinitionDocument` 当前为结构体，Swift 会要求所有存储属性在 `init` 中赋值。找到其 `init` 方法（或 memberwise init 的调用点），在 `disallowedToolNames` 参数之后加一行：

```swift
isOneShot: Bool = false
```

并在 `init` 体中赋值：

```swift
self.isOneShot = isOneShot
```

> 注：如果 `AgentDefinitionDocument` 使用 memberwise init（无自定义 `init`），则只需新增属性声明，Swift 自动在 memberwise init 末尾添加该参数；所有调用点需同步更新（下一 Task 会处理）。

**Step 5: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task1 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：所有 `AgentDefinitionLoaderOpenAgentTests` 用例 PASS（`isOneShot` 默认 `false` 断言通过）。

**Step 6: Commit**

```
git add agentGui/Models/AgentDefinitionDocument.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "feat(S-A2): add isOneShot field to AgentDefinitionDocument"
```

---

## Task 2：在 AgentDefinitionLoader 里解析 one-shot 字段

**Files:**
- Modify: `agentGui/Services/AgentDefinitionLoader.swift`
- Modify: `agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift`

**Step 1: 补充 frontmatter 解析测试**

在 `test_documentParsesAllOptionalFields()` 的 raw frontmatter 字符串中，在 `disallowed-tools: [bash_write, file_delete]` 行之后添加：

```yaml
one-shot: true
```

更新同一测试底部的断言（将 `XCTAssertFalse(doc.isOneShot)` 改为）：

```swift
XCTAssertTrue(doc.isOneShot)
```

新增一个专门测试缺省值的用例，在 `test_documentDefaultsForOptionalFields()` 里确认：

```swift
XCTAssertFalse(doc.isOneShot)   // 已在 Task 1 中添加，此处确认仍在
```

新增一个解析"不支持字段"的负向测试（验证 Loader 不接受拼写错误）：

```swift
func test_unsupportedField_oneShotTypo_throwsError() throws {
    let raw = """
        ---
        name: myagent
        display-name: My Agent
        description: Test.
        argument-hint: Test.
        tools: [read_only_editor]
        max-turns: 10
        user-invocable: false
        subagent-invocable: true
        output-contract: test_report
        oneshot: true
        ---
        # Role
        Body.
        """
    let loader = AgentDefinitionLoader()
    XCTAssertThrowsError(try loader.parseDocument(named: "myagent.agent.md", raw: raw)) { error in
        guard case AgentValidationError.unsupportedFields(let fields) = error else {
            XCTFail("Expected unsupportedFields, got \(error)")
            return
        }
        XCTAssertTrue(fields.contains("oneshot"))
    }
}
```

**Step 2: 运行测试，确认失败**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task2 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：`test_documentParsesAllOptionalFields` 断言 `doc.isOneShot == true` 失败（Loader 尚未解析该字段）。

**Step 3: 在 AgentDefinitionLoader.swift 中添加解析逻辑**

① 在 `optionalFields` 集合中添加 `"one-shot"`：

```swift
private let optionalFields: Set<String> = [
    "model-preference",
    "effort",
    "background",
    "omit-main-context",
    "initial-prompt",
    "critical-reminder",
    "color",
    "disallowed-tools",
    "one-shot",      // S-A2
    "tags",
    "examples",
    "notes"
]
```

② 在 `parseDocument` 方法中，紧接 `disallowedToolNames` 解析段之后（`return AgentDefinitionDocument(` 之前）添加：

```swift
// MARK: S-A2 — one-shot flag
let isOneShot = parseBool(parsed.fields["one-shot"] ?? "false") ?? false
```

③ 在 `return AgentDefinitionDocument(...)` 调用中，在 `disallowedToolNames: disallowedToolNames` 后追加：

```swift
isOneShot: isOneShot
```

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task2 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED"
```

预期：全部 `AgentDefinitionLoaderOpenAgentTests` PASS。

**Step 5: Commit**

```
git add agentGui/Services/AgentDefinitionLoader.swift agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "feat(S-A2): parse one-shot frontmatter field in AgentDefinitionLoader"
```

---

## Task 3：透传 isOneShot 至 AgentRuntimeDefinition 和 WorkflowRoleDefinition

**Files:**
- Modify: `agentGui/Models/AgentRuntimeDefinition.swift`
- Modify: `agentGui/Models/WorkflowRoleDefinition.swift`

> 纯透传，不含逻辑判断。完成后可独立编译。

**Step 1: 写编译验证注释（不需要专门写新 test，依赖整体编译通过）**

此 Task 改动量大（多处 init 参数），先让编译报错引导修改位置。

**Step 2: 在 WorkflowRoleDefinition.swift 中添加 isOneShot 属性**

在 `// MARK: - S-A1 Execution Traits` 段的 `disallowedToolNames` 之后添加：

```swift
    // MARK: - S-A2 One-Shot Trailer Skip
    /// `true` 时子代理结果不附加执行元数据 trailer。
    let isOneShot: Bool
```

在 `init(...)` 的参数列表中，在 `disallowedToolNames: [String] = []` 之后添加：

```swift
        isOneShot: Bool = false
```

在 `init` 体中赋值：

```swift
        self.isOneShot = isOneShot
```

**Step 3: 在 AgentRuntimeDefinition.swift 中添加 isOneShot 属性**

在 `// MARK: - S-A1 Optional execution-trait fields` 段的 `disallowedToolNames` 之后添加：

```swift
    // MARK: - S-A2
    let isOneShot: Bool
```

**Step 4: 更新 AgentRuntimeDefinition.workflowRoleDefinition 计算属性**

在 `WorkflowRoleDefinition(...)` 初始化调用的末尾（`disallowedToolNames: disallowedToolNames` 之后）追加：

```swift
            isOneShot: isOneShot
```

**Step 5: 更新 AgentRuntimeDefinition.make(from:) 的所有分支**

`make(from:)` 中有 `explore` / `worker` / `verifier` / `default` 四个 `return AgentRuntimeDefinition(...)` 调用。每个调用在 `disallowedToolNames: document.disallowedToolNames` 之后追加：

```swift
                isOneShot: document.isOneShot
```

**Step 6: 编译确认无报错**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-s-a2-task3 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

预期：`Build succeeded`

**Step 7: 运行全量 Loader 测试，确认无回归**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task3 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED"
```

预期：全部通过。

**Step 8: Commit**

```
git add agentGui/Models/AgentRuntimeDefinition.swift agentGui/Models/WorkflowRoleDefinition.swift
git commit -m "feat(S-A2): thread isOneShot through AgentRuntimeDefinition and WorkflowRoleDefinition"
```

---

## Task 4：在 runSubagentLoop 中实现条件 Trailer

**Files:**
- Modify: `agentGui/Services/ClaudeService/ClaudeService+Subagent.swift`
- Create: `agentGuiTests/OneShotSubagentTrailerTests.swift`

**Step 1: 创建测试文件，写出 trailer 行为的单元测试**

`runSubagentLoop` 是一个私有方法，且需要真实 API 调用，无法直接单元测试。因此提取 trailer 构建逻辑为 `internal`（测试可见）的纯函数，在专属测试文件中验证。

新建 `agentGuiTests/OneShotSubagentTrailerTests.swift`：

```swift
import XCTest
@testable import agentGui

// MARK: - OneShotSubagentTrailerTests
//
// 验证 S-A2 的核心行为：buildSubagentTrailer 函数根据 isOneShot 标记
// 决定是否产生 trailer 文本。

final class OneShotSubagentTrailerTests: XCTestCase {

    // MARK: - buildSubagentTrailer

    func test_nonOneShotAgent_returnsNonEmptyTrailer() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "worker",
            rounds: 4,
            elapsed: 12.34,
            isOneShot: false
        )
        XCTAssertNotNil(trailer, "非 one-shot 代理应产生 trailer")
        XCTAssertTrue(trailer!.contains("worker"),   "trailer 应含代理名称")
        XCTAssertTrue(trailer!.contains("rounds: 4"), "trailer 应含轮次")
        XCTAssertTrue(trailer!.contains("elapsed"),  "trailer 应含耗时")
    }

    func test_oneShotAgent_returnsNilTrailer() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "explore",
            rounds: 8,
            elapsed: 5.0,
            isOneShot: true
        )
        XCTAssertNil(trailer, "one-shot 代理不应产生 trailer")
    }

    func test_trailerIsWrappedInXMLTag() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "verifier",
            rounds: 2,
            elapsed: 3.1,
            isOneShot: false
        )!
        XCTAssertTrue(trailer.contains("<agent_execution>"), "trailer 应使用 <agent_execution> XML 包裹")
        XCTAssertTrue(trailer.contains("</agent_execution>"), "trailer 应有闭合标签")
    }

    func test_trailerLeadingNewline() {
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: "worker",
            rounds: 1,
            elapsed: 0.5,
            isOneShot: false
        )!
        XCTAssertTrue(trailer.hasPrefix("\n"), "trailer 应以换行开头，与正文分隔")
    }

    // MARK: - applyTrailerToOutput

    func test_applyTrailer_nonOneShotAppendsTrailer() {
        let output = "Found 3 relevant files."
        let result = ClaudeService.applyTrailerToOutput(
            output: output,
            trailer: "\n<agent_execution>agent: worker | rounds: 1 | elapsed: 0.50s</agent_execution>"
        )
        XCTAssertTrue(result.hasPrefix("Found 3 relevant files."))
        XCTAssertTrue(result.contains("<agent_execution>"))
    }

    func test_applyTrailer_nilTrailerReturnsOutputUnchanged() {
        let output = "Exploration complete.\n\n## Files Found\n- src/main.swift"
        let result = ClaudeService.applyTrailerToOutput(output: output, trailer: nil)
        XCTAssertEqual(result, output, "nil trailer 时输出不应改变")
    }
}
```

**Step 2: 运行测试，确认编译失败（函数不存在）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -derivedDataPath /tmp/agentGui-s-a2-task4 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build FAILED"
```

预期：`error: type 'ClaudeService' has no member 'buildSubagentTrailer'`

**Step 3: 在 ClaudeService+Subagent.swift 中实现 buildSubagentTrailer 和 applyTrailerToOutput**

在文件末尾（`extension ClaudeService` 内，私有方法之后）添加：

```swift
    // MARK: - S-A2 One-Shot Trailer

    /// 根据 isOneShot 标记生成执行元数据 trailer。
    /// - Returns: 追加在输出末尾的字符串（以 `\n` 开头），或 `nil`（one-shot 代理跳过）。
    static func buildSubagentTrailer(
        agentName: String,
        rounds: Int,
        elapsed: TimeInterval,
        isOneShot: Bool
    ) -> String? {
        guard !isOneShot else { return nil }
        let elapsedStr = String(format: "%.2fs", elapsed)
        return "\n<agent_execution>agent: \(agentName) | rounds: \(rounds) | elapsed: \(elapsedStr)</agent_execution>"
    }

    /// 将 trailer（可为 nil）追加到输出文本末尾。
    static func applyTrailerToOutput(output: String, trailer: String?) -> String {
        guard let trailer else { return output }
        return output + trailer
    }
```

**Step 4: 运行测试，确认通过**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -derivedDataPath /tmp/agentGui-s-a2-task4 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED"
```

预期：所有 `OneShotSubagentTrailerTests` PASS。

**Step 5: 将 trailer 逻辑接入 runSubagentLoop**

找到 `runSubagentLoop` 内以下代码段：

```swift
        let output = result.text.isEmpty ? "(subagent produced no output)" : result.text
        let elapsed = Date().timeIntervalSince(startTime)
        let metadata: [String: String] = [
            "agent":    definition.name,
            "rounds":   String(min(loopMessages.count / 2, definition.maxRounds)),
            "elapsed":  String(format: "%.2fs", elapsed)
        ]
        return .detecting(text: output, sender: definition.name, metadata: metadata)
```

替换为：

```swift
        let rawOutput = result.text.isEmpty ? "(subagent produced no output)" : result.text
        let elapsed = Date().timeIntervalSince(startTime)
        let rounds = min(loopMessages.count / 2, definition.maxRounds)
        let trailer = ClaudeService.buildSubagentTrailer(
            agentName: definition.name,
            rounds: rounds,
            elapsed: elapsed,
            isOneShot: definition.isOneShot
        )
        let output = ClaudeService.applyTrailerToOutput(output: rawOutput, trailer: trailer)
        let metadata: [String: String] = [
            "agent":    definition.name,
            "rounds":   String(rounds),
            "elapsed":  String(format: "%.2fs", elapsed)
        ]
        return .detecting(text: output, sender: definition.name, metadata: metadata)
```

**Step 6: 编译确认**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-s-a2-task4 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "error:|Build succeeded|Build FAILED"
```

**Step 7: 再次运行 trailer 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -derivedDataPath /tmp/agentGui-s-a2-task4 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED"
```

**Step 8: Commit**

```
git add agentGui/Services/ClaudeService/ClaudeService+Subagent.swift \
        agentGuiTests/OneShotSubagentTrailerTests.swift
git commit -m "feat(S-A2): implement conditional trailer in runSubagentLoop via buildSubagentTrailer"
```

---

## Task 5：给 explore.agent.md 设置 one-shot: true

**Files:**
- Modify: `agentGui/Resources/Agents/explore.agent.md`

> explore 代理是只读报告代理，结果自足，不需要 trailer。与 Claude Code `ONE_SHOT_BUILTIN_AGENT_TYPES` 的 `'Explore'` 对齐。

**Step 1: 修改 explore.agent.md 的 frontmatter**

在 `output-contract: exploration_report` 行之后添加：

```yaml
one-shot: true
```

完整 frontmatter 更新为：

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
---
```

**Step 2: 运行 Loader 测试，确认 explore 的 isOneShot 为 true**

在 `AgentDefinitionLoaderOpenAgentTests.swift` 添加一个用例，验证内置 explore 定义的 one-shot 标记：

```swift
func test_builtInExploreAgentHasOneShotEnabled() throws {
    let loader = AgentDefinitionLoader()
    let documents = try loader.loadBuiltInDocuments(from: Bundle(for: type(of: self)))
    let explore = try XCTUnwrap(documents.first { $0.name == "explore" })
    XCTAssertTrue(explore.isOneShot, "explore 代理应标记为 one-shot")
}

func test_builtInWorkerAgentHasOneShotDisabled() throws {
    let loader = AgentDefinitionLoader()
    let documents = try loader.loadBuiltInDocuments(from: Bundle(for: type(of: self)))
    let worker = try XCTUnwrap(documents.first { $0.name == "worker" })
    XCTAssertFalse(worker.isOneShot, "worker 代理不应标记为 one-shot")
}
```

**Step 3: 运行测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -derivedDataPath /tmp/agentGui-s-a2-task5 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED"
```

预期：全部通过。

**Step 4: Commit**

```
git add agentGui/Resources/Agents/explore.agent.md \
        agentGuiTests/AgentDefinitionLoaderOpenAgentTests.swift
git commit -m "feat(S-A2): mark explore agent as one-shot, add built-in loader regression tests"
```

---

## Task 6：端到端回归验证

**Goal:** 确认 S-A2 改动未破坏现有已通过功能。

**Step 1: 运行 Loader 相关测试套件**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -only-testing:agentGuiTests/AgentDefinitionLoaderOpenAgentTests \
  -only-testing:agentGuiTests/OneShotSubagentTrailerTests \
  -derivedDataPath /tmp/agentGui-s-a2-final \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASS，零错误。

**Step 2: 运行 ACP 相关测试（确认 WorkflowRoleDefinition 透传未破坏 ACP 体系）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ACPExternalExecutionProviderBaseTests \
  -only-testing:agentGuiTests/DynamicACPExternalExecutionProviderTests \
  -derivedDataPath /tmp/agentGui-s-a2-acp-check \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "PASSED|FAILED|error:"
```

预期：全部 PASS。

**Step 3: 完成后提交 Feature 收尾 Commit**

```
git commit --allow-empty -m "feat(S-A2): one-shot agent trailer skip complete — all tests pass"
```

---

## 验收标准检查清单

| 验收标准 | 对应 Task | 验证方式 |
|---|---|---|
| `isOneShot: Bool` 字段存在于 `WorkflowRoleDefinition` | Task 1–3 | 编译通过 |
| `one-shot: true` frontmatter 可被正确解析 | Task 2 | `test_documentParsesAllOptionalFields` |
| 未设置 `one-shot` 时默认 `false` | Task 2 | `test_documentDefaultsForOptionalFields` |
| explore 内置代理的 `isOneShot == true` | Task 5 | `test_builtInExploreAgentHasOneShotEnabled` |
| worker 内置代理的 `isOneShot == false` | Task 5 | `test_builtInWorkerAgentHasOneShotDisabled` |
| `buildSubagentTrailer(isOneShot: true)` 返回 nil | Task 4 | `test_oneShotAgent_returnsNilTrailer` |
| `buildSubagentTrailer(isOneShot: false)` 返回非空字符串 | Task 4 | `test_nonOneShotAgent_returnsNonEmptyTrailer` |
| Trailer 以 `\n<agent_execution>` 包裹 | Task 4 | `test_trailerIsWrappedInXMLTag` |
| `applyTrailerToOutput(trailer: nil)` 不改变输出 | Task 4 | `test_applyTrailer_nilTrailerReturnsOutputUnchanged` |
| 现有 Agent 测试无回归 | Task 6 | ACP 和 Loader 测试全绿 |
