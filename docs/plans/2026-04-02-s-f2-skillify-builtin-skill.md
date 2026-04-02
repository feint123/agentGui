# S-F2: Skillify 内置技能 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Claude Code 的 `skillify` 工作流迁移为 agentGui 内置技能，让 built-in agent 在会话结束后能将本次成功流程通过多轮问答提炼写成 SKILL.md 文件，沉淀为可复用的本地技能，并在写入后触发 `SkillService` 自动刷新。

**Architecture:** 新增 `SkillifySkill.swift`（位于 `agentGui/Services/BuiltInSkills/`）和目录创建辅助 `SkillifySkillPrompt.swift`（同目录，纯字符串常量，方便维护）。在 `agentGuiApp.swift` 的 `init()` 中调用 `registerSkillifySkill()` 注册到 `BuiltInSkillRegistry.shared`。Skillify 的 prompt 需要从当前会话的 `messagesSnapshot` 中提取用户消息（与 Claude Code 的 `extractUserMessages()` 同功能），并通过内置变量 `{{userMessages}}` 和 `{{sessionMemory}}` 动态填充 prompt 模板。由于 agentGui 无 SessionMemory 云服务，`sessionMemory` 来源改为 `RMSInsightStore`（已有实现，与 memory extraction 路径一致）。

**Tech Stack:** Swift 6, SwiftUI, SwiftAnthropic，现有 `BuiltInSkillRegistry` / `SkillService` / `RMSInsightStore` / `AgentLoopHookContext.messagesSnapshot` / `MessageParameter.Message`

**依赖前置条件（已完成）:**
- S-F1: `BuiltInSkillRegistry` / `BuiltInSkillDefinition` 已在 `BuiltInSkillRegistry.swift` 中存在 ✅
- S-C1: `skill_invoke` 工具已在 `ClaudeService+ToolDispatch.swift` 中存在 ✅
- S-D1: `SkillArgumentSubstitution.substitute()` 已在 `SkillArgumentSubstitution.swift` 中存在 ✅
- `RMSInsightStore` 已在 `Services/` 中实现（用于 memory extraction 路径）✅
- `SkillService.loadSkills()` + `availableSkills` 已存在，支持合并 bundled skills ✅

---

## 参考：Claude Code 对标

| Claude Code (`skillify.ts`) | agentGui 对应 |
|---|---|
| `extractUserMessages(messages)` | `SkillifyPromptBuilder.extractUserMessages(from: [MessageParameter.Message])` |
| `getSessionMemoryContent()` （ANT AKI 服务） | `RMSInsightStore().load(scope: .user)` 拼成字符串（离线） |
| `SKILLIFY_PROMPT` 模板字符串 | `SkillifySkillContent.prompt` 静态常量 |
| `registerBundledSkill(...)` | `BuiltInSkillRegistry.shared.register(...)` |
| `context.messages` （注入消息快照） | `getPromptContent` 闭包接收 `args` — `args` 对 skillify 是可选描述；消息快照通过 **skill 特殊路径** 传入（见 Task 4） |
| `AskUserQuestion` 工具调用 | `ask_user_question`（agentGui 已有内置工具） |
| 写入 `.claude/skills/<name>/SKILL.md` | `write_file` 工具写入目标路径 |

Claude Code 中 ANT-only 逻辑（`USER_TYPE !== 'ant'` guard、Slack 通知、BigQuery 日志、`registerIfAnt()`）**不迁移**。

---

## 关键文件

| 路径 | 变更类型 |
|---|---|
| `agentGui/Services/BuiltInSkills/SkillifySkill.swift` | **新建** — 注册函数 + prompt builder |
| `agentGui/agentGuiApp.swift` | **修改** — `init()` 中调用 `registerSkillifySkill()` |
| `agentGuiTests/SkillifySkillTests.swift` | **新建** — 单元测试 |

不修改：
- `BuiltInSkillRegistry.swift` — 已有注册机制
- `SkillService.swift` — `availableSkills` 合并 bundled skills 的路径已存在
- `ClaudeService+ToolDispatch.swift` — `skill_invoke` 工具路径已存在
- `SkillArgumentSubstitution.swift` — 触发时已在 SkillInvocationProcessor 完成替换

---

## 设计决策：消息上下文传递

Skillify 是内置 skill，其 `getPromptContent` 闭包在 `BuiltInSkillDefinition` 中定义，目前签名为 `@Sendable () async -> String`，无法直接接收 `messagesSnapshot`。

**解决方案（轻量）：** skillify 的 prompt 模板中包含占位符 `$ARGUMENTS`。用户调用时可通过 `skill_invoke skillify "描述本次流程"` 传入描述，这段描述作为 `{{userDescriptionBlock}}` 填入。消息快照暂不注入 prompt（与设计文档 S-F2 说明一致：agentGui 版为简化版，去掉了 ANT SessionMemory 依赖）。`sessionMemory` 改为从 `RMSInsightStore` 读取。

若后续需要传入完整消息快照，可扩展 `BuiltInSkillDefinition.getPromptContent` 签名为 `@Sendable (_ args: String?) async -> String`（当前签名），并在 `SkillInvocationProcessor` 里额外传递可选的 `messagesSnapshot`。本计划不实现该扩展，YAGNI。

---

## Task 1: 新建 `SkillifySkillTests.swift` 并写失败测试

**文件：** 新建 `agentGuiTests/SkillifySkillTests.swift`

**Step 1: 写出测试骨架**

```swift
// agentGuiTests/SkillifySkillTests.swift
import XCTest
@testable import agentGui

final class SkillifySkillTests: XCTestCase {

    private var registry: BuiltInSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = BuiltInSkillRegistry()
        registerSkillifySkill(into: registry)
    }

    // MARK: - 注册验证

    func test_registration_skillAppearsInRegistry() {
        let skills = registry.allSkills()
        XCTAssertTrue(
            skills.contains(where: { $0.directoryName == "skillify" }),
            "skillify 应出现在 allSkills() 中"
        )
    }

    func test_registration_loadedFromBundled() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_registration_userInvocableTrue() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertTrue(skill.userInvocable)
    }

    func test_registration_disableModelInvocationFalse() {
        // agentGui 版：允许模型主动调用，去掉 ANT 的 disableModelInvocation guard
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertFalse(skill.disableModelInvocation)
    }

    func test_registration_hasAllowedTools() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertFalse(skill.allowedTools.isEmpty, "skillify 应声明所需工具权限")
    }

    func test_registration_hasWhenToUse() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertNotNil(skill.whenToUse)
        XCTAssertFalse(skill.whenToUse!.isEmpty)
    }

    func test_registration_hasArgumentHint() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertNotNil(skill.argumentHint)
    }

    func test_registration_executionContextInline() {
        // skillify 需要中途用户确认，使用 inline 模式
        let skill = registry.allSkills().first(where: { $0.directoryName == "skillify" })!
        XCTAssertEqual(skill.executionContext, .inline)
    }

    // MARK: - Prompt 内容验证

    func test_promptContent_containsAnalyzeSessionSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Analyze the Session") || content!.contains("分析本次会话"),
            "prompt 应包含会话分析步骤"
        )
    }

    func test_promptContent_containsInterviewUserSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Interview") || content!.contains("问答") || content!.contains("AskUserQuestion"),
            "prompt 应包含用户问答步骤"
        )
    }

    func test_promptContent_containsWriteSkillMDSection() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("SKILL.md"),
            "prompt 应包含 SKILL.md 写入步骤"
        )
    }

    func test_promptContent_argumentsPlaceholderPresent() async {
        let content = await registry.promptContent(skillName: "skillify")
        XCTAssertNotNil(content)
        // 若 args 有可选描述，prompt 应有相应占位符
        XCTAssertTrue(
            content!.contains("$ARGUMENTS") || content!.contains("{{userDescriptionBlock}}"),
            "prompt 中应含可选描述占位符"
        )
    }

    // MARK: - extractUserMessages

    func test_extractUserMessages_filterUserRole() {
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("hello")),
            .init(role: .assistant, content: .text("world")),
            .init(role: .user, content: .text("second")),
        ]
        let result = SkillifyPromptBuilder.extractUserMessages(from: msgs)
        XCTAssertEqual(result, ["hello", "second"])
    }

    func test_extractUserMessages_skipsEmptyText() {
        let msgs: [MessageParameter.Message] = [
            .init(role: .user, content: .text("")),
            .init(role: .user, content: .text("  ")),
            .init(role: .user, content: .text("valid")),
        ]
        let result = SkillifyPromptBuilder.extractUserMessages(from: msgs)
        XCTAssertEqual(result, ["valid"])
    }

    func test_extractUserMessages_emptyMessages_returnsEmpty() {
        let result = SkillifyPromptBuilder.extractUserMessages(from: [])
        XCTAssertTrue(result.isEmpty)
    }
}
```

**Step 2: 运行测试，确认编译失败（类型不存在）**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  -only-testing:agentGuiTests/SkillifySkillTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

预期：编译失败，`registerSkillifySkill` / `SkillifyPromptBuilder` 未找到。

**Step 3: Commit 测试骨架**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
git add agentGuiTests/SkillifySkillTests.swift
git commit -m "test(S-F2): add failing tests for SkillifySkill registration and prompt"
```

---

## Task 2: 新建 `SkillifySkill.swift`（注册函数 + prompt builder）

**文件：** 新建 `agentGui/Services/BuiltInSkills/SkillifySkill.swift`

注意：需要先在 Xcode 中将此目录和文件加入 target。推荐直接在 Xcode Project Navigator 中新建 group `BuiltInSkills` 并创建文件（勾选 target membership）。或通过下面 Task 2 末尾的 Step 3 手工添加到 pbxproj。

**Step 1: 创建文件**

```swift
//
//  SkillifySkill.swift
//  agentGui
//

import Foundation
import SwiftAnthropic

// MARK: - Prompt Builder

/// Skillify 技能的 prompt 组装器。
/// 对应 Claude Code `skillify.ts` → `extractUserMessages()` + `SKILLIFY_PROMPT`。
enum SkillifyPromptBuilder {

    // MARK: - User Message Extraction

    /// 从消息快照中提取所有用户消息的文本内容（过滤空内容）。
    /// 对应 Claude Code `extractUserMessages(messages: Message[])`。
    static func extractUserMessages(from messages: [MessageParameter.Message]) -> [String] {
        messages.compactMap { msg -> String? in
            guard msg.role == .user else { return nil }
            let text: String
            switch msg.content {
            case .text(let t):
                text = t
            case .list(let blocks):
                text = blocks.compactMap { block -> String? in
                    if case .text(let t) = block { return t.text }
                    return nil
                }.joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Prompt Assembly

    /// 组装最终注入给模型的 prompt 字符串。
    /// - Parameters:
    ///   - args: 用户/模型传入的可选描述（`$ARGUMENTS` 替换后的值）。
    ///   - sessionMemoryLines: 来自 `RMSInsightStore` 的 insight 摘要行，逐行拼接。
    ///   - userMessages: 已过滤的用户消息文本列表。
    static func buildPrompt(
        args: String?,
        sessionMemoryLines: [String],
        userMessages: [String]
    ) -> String {
        let userDescriptionBlock = args.map { "The user described this process as: \"\($0)\"" } ?? ""
        let sessionMemory = sessionMemoryLines.isEmpty
            ? "No session memory available."
            : sessionMemoryLines.joined(separator: "\n")
        let userMessagesText = userMessages.isEmpty
            ? "(No user messages found in this session.)"
            : userMessages.joined(separator: "\n\n---\n\n")

        return skillifyPromptTemplate
            .replacingOccurrences(of: "{{sessionMemory}}", with: sessionMemory)
            .replacingOccurrences(of: "{{userMessages}}", with: userMessagesText)
            .replacingOccurrences(of: "{{userDescriptionBlock}}", with: userDescriptionBlock)
    }
}

// MARK: - Registration

/// 将 skillify 注册到指定的 `BuiltInSkillRegistry`（默认为 `.shared`）。
/// 在 `agentGuiApp.init()` 中调用一次。
///
/// - Parameter registry: 注册目标，测试时传入独立实例。
func registerSkillifySkill(into registry: BuiltInSkillRegistry = .shared) {
    registry.register(BuiltInSkillDefinition(
        name: "skillify",
        description: "将当前会话的可复现流程提炼为 SKILL.md，存入本地技能库。",
        whenToUse: "Use when the user says '把这次过程保存为技能', '记住这个工作流', 'save this as a skill', or wants to capture a repeatable process. Examples: 'skillify', 'save workflow', 'make this a skill'.",
        argumentHint: "[可选：描述你想捕获的流程]",
        argumentNames: [],
        allowedTools: [
            "read_file",
            "write_file",
            "create_directory",
            "ask_user_question",
        ],
        model: nil,
        effort: nil,
        executionContext: .inline,
        agent: nil,
        userInvocable: true,
        disableModelInvocation: false,
        version: "1.0",
        isEnabled: nil,
        getPromptContent: {
            // args 此时已经由 SkillInvocationProcessor 替换 $ARGUMENTS，
            // 但 getPromptContent 不接收 args 参数。
            // Skillify prompt 返回含 $ARGUMENTS 占位符的模板；
            // SkillArgumentSubstitution 在 SkillInvocationProcessor.invoke() 中完成替换。
            // sessionMemory 和 userMessages 均由模型在执行时通过 read_file / RMS 工具自行获取，
            // 或从 prompt 中的占位符说明中了解如何读取。
            //
            // 注意：Claude Code 的版本在 `getPromptForCommand(args, context)` 中
            // 直接调用 getSessionMemoryContent() 并注入 context.messages。
            // agentGui 简化版：prompt 说明模型使用 read_skill 工具读取会话上下文，
            // 不在此处做动态注入。
            skillifyPromptTemplate
        }
    ))
}

// MARK: - Prompt Template

/// Skillify 工作流 prompt 模板。
/// 对应 Claude Code `SKILLIFY_PROMPT` 常量。
///
/// 占位符：
/// - `$ARGUMENTS`  — 调用时用户可选传入的描述（由 SkillArgumentSubstitution 替换）
private let skillifyPromptTemplate = """
# Skillify $ARGUMENTS

You are capturing this session's repeatable process as a reusable skill.

## Context

Review the recent conversation history above (the messages before this one) to understand what was accomplished.

Pay close attention to:
- What the user asked you to do
- The steps you took to accomplish it
- Where the user corrected or steered you
- What tools and commands were used
- What the final success criteria were

## Your Task

### Step 1: Analyze the Session

Before asking any questions, analyze the conversation to identify:
- What repeatable process was performed
- What the inputs/parameters were
- The distinct steps (in order)
- The success artifacts/criteria for each step
- Where the user corrected or steered you
- What tools and permissions were needed
- What the goals and success artifacts were

### Step 2: Interview the User

Use the `ask_user_question` tool for ALL questions. Never ask questions via plain text.

**Round 1: High level confirmation**
- Suggest a name and description for the skill based on your analysis.
- Ask the user to confirm or rename.
- Suggest high-level goal(s) and specific success criteria for the skill.

**Round 2: More details**
- Present the high-level steps you identified as a numbered list.
- If the skill will require arguments, suggest them based on what you observed.
- Ask if this skill should run inline (in the current conversation) or forked (as a sub-agent with its own context).
  - Forked is better for self-contained tasks that don't need mid-process user input.
  - Inline is better when the user wants to steer mid-process.
- Ask where the skill should be saved:
  - **This repo** (`.claude/skills/<name>/SKILL.md`) — for workflows specific to this project
  - **Personal** (`~/.claude/skills/<name>/SKILL.md`) — follows you across all repos

**Round 3: Breaking down each step**
For each major step (if not glaringly obvious), ask:
- What does this step produce that later steps need?
- What proves that this step succeeded?
- Should the user be asked to confirm before proceeding? (especially for irreversible actions)

Do multiple rounds if needed. Stop interviewing once you have enough information.
IMPORTANT: Don't over-ask for simple processes.

### Step 3: Write the SKILL.md

Create the skill directory using `create_directory`, then write the file using `write_file`.

Use this SKILL.md format:

```markdown
---
name: {{skill-name}}
description: {{one-line description}}
allowed-tools:
  - {{tool1}}
  - {{tool2}}
when_to_use: {{detailed description of when Claude should auto-invoke this skill, including trigger phrases}}
argument-hint: "{{hint showing argument placeholders}}"
arguments:
  - {{arg1}}
context: {{inline or fork — omit entirely for inline}}
---

# {{Skill Title}}

{{Description of skill}}

## Inputs
- `$arg_name`: Description of this input

## Goal
Clearly stated goal for this workflow, with defined success criteria.

## Steps

### 1. Step Name
What to do in this step. Be specific and actionable.

**Success criteria**: Always include this. Shows that the step is done and we can move on.
```

### Step 4: Confirm and Save

Before writing the file, output the complete SKILL.md content in a markdown code block so the user can review it.

Then use `ask_user_question` to confirm: "Does this SKILL.md look good to save?"

After writing, tell the user:
- Where the skill was saved
- How to invoke it: `/{{skill-name}} [arguments]`
- That they can edit the SKILL.md directly to refine it
"""
```

**Step 2: 将文件加入 Xcode target**

由于 Xcode 的 `project.pbxproj` 必须通过 Xcode GUI 或 `project.pbxproj` 手工编辑，推荐在 Xcode 中：

1. 在 Project Navigator → `agentGui/Services/` 下 Right-click → "New Group" → 命名 `BuiltInSkills`
2. 在新建 group 内 `File` → "New File..." → Swift File → 命名 `SkillifySkill.swift`
3. 将上述代码替换自动生成的内容（确认 Target Membership 勾选 `agentGui`）

如改用终端创建文件后手工加入 pbxproj，需在 `project.pbxproj` 文件中的 `PBXBuildFile`、`PBXFileReference` 和对应 `PBXGroup` 节点添加条目——可用 `ruby scripts/add_file.rb` 或直接在 Xcode 中 drag-in。

**Step 3: 编译确认文件可见**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：BUILD SUCCEEDED（或只有与本变更无关的警告）。

**Step 4: Commit**

```bash
git add agentGui/Services/BuiltInSkills/SkillifySkill.swift
git add agentGui.xcodeproj/project.pbxproj
git commit -m "feat(S-F2): add SkillifySkill with prompt builder and registration function"
```

---

## Task 3: 在 `agentGuiApp.swift` 中注册 skillify

**文件：** `agentGui/agentGuiApp.swift`

**Step 1: 在 `init()` 中调用注册函数**

找到 `agentGuiApp.init()` 中的：

```swift
init() {
    ConfigDirectoryManager.shared.setup()
    NSWindow.allowsAutomaticWindowTabbing = true
}
```

修改为：

```swift
init() {
    ConfigDirectoryManager.shared.setup()
    NSWindow.allowsAutomaticWindowTabbing = true
    // 注册内置技能（S-F1/S-F2）
    registerSkillifySkill()
}
```

**Step 2: 编译确认无错误**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

预期：BUILD SUCCEEDED。

**Step 3: Commit**

```bash
git add agentGui/agentGuiApp.swift
git commit -m "feat(S-F2): register skillify built-in skill at app startup"
```

---

## Task 4: 运行测试，验证绿灯

**Step 1: 运行 Skillify 专项测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  -only-testing:agentGuiTests/SkillifySkillTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case|Passed|Failed)|ERROR|FAILED|PASSED"
```

预期：所有 `SkillifySkillTests` 测试 PASSED。

**Step 2: 运行 BuiltInSkillRegistry 回归测试，确保注册机制未受影响**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case|Passed|Failed)|ERROR|FAILED|PASSED"
```

预期：所有 `BuiltInSkillRegistryTests` 测试 PASSED。

**Step 3: 若有失败，修复后重跑**

常见问题：
- `MessageParameter.Message` 的 `content` 初始化格式——检查 SwiftAnthropic 中 `.list` 关联值的实际类型。
- `ask_user_question` 工具名称——确认在 `ClaudeService+ToolBuilder.swift` 中的注册名称与 prompt 一致。

**Step 4: Commit（若有修复）**

```bash
git add -A
git commit -m "fix(S-F2): fix test compilation issues in SkillifySkillTests"
```

---

## Task 5: 验证 skillify 在 SkillService 的 availableSkills 中可见

**Step 1: 写集成验证测试**

在 `SkillifySkillTests.swift` 末尾追加：

```swift
// MARK: - SkillService 集成（快速路径验证）

func test_skillifyAppearsInSkillServiceWhenRegistered() async {
    // 使用独立 registry 模拟注册，验证 SkillService 合并逻辑
    let localRegistry = BuiltInSkillRegistry()
    registerSkillifySkill(into: localRegistry)

    let bundledSkills = localRegistry.allSkills()
    XCTAssertTrue(
        bundledSkills.contains(where: { $0.directoryName == "skillify" && $0.loadedFrom == .bundled }),
        "skillify 应在 bundled skills 中，供 SkillService.availableSkills 合并"
    )
}
```

**Step 2: 运行新增测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination "platform=macOS" \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-sf2-derived \
  -only-testing:agentGuiTests/SkillifySkillTests \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test (Suite|Case|Passed|Failed)|FAILED|PASSED"
```

预期：PASSED。

**Step 3: Commit**

```bash
git add agentGuiTests/SkillifySkillTests.swift
git commit -m "test(S-F2): add SkillService integration verification test for skillify"
```

---

## Task 6: 验收检查表

完成以下手动验收确认（可在开发机上运行 app 验证）：

| 验收点 | 验证方法 |
|--------|----------|
| skillify 出现在 SkillsView 中 | 运行 app → 打开 Skills 列表，应看到 "skillify" 条目，来源标签为 bundled |
| skillify 不受用户 enable/disable 控制 | 在 SkillsView 中确认 skillify 没有开关（bundled skill 不受 `enabledSkillNames` 约束） |
| 模型可以通过 `skill_invoke` 触发 | 在 chat 中说"把这次过程保存为技能"，agent 应调用 `skill_invoke skillify` |
| Prompt 中包含 ask_user_question 步骤 | 触发后，模型应通过 `ask_user_question` 询问技能名称 |
| 写入 SKILL.md 后，SkillService 自动刷新 | 写入后，SkillsView 中应出现新技能（需 app 监听文件系统变化，或手动 reload）|

注意：最后一项（文件系统变化自动刷新）超出 S-F2 范围，属于 S-A3 动态发现。本实现只保证写入完成后通知用户路径——自动刷新由后续 S-A3 处理。

---

## 附录：设计说明

### 为什么不注入 messagesSnapshot？

Claude Code 的 `getPromptForCommand(args, context)` 通过 `context.messages` 注入完整消息快照，让 skillify prompt 包含本轮所有用户消息文本。agentGui 的 `BuiltInSkillDefinition.getPromptContent` 当前签名为 `@Sendable () async -> String`，不接受消息上下文参数。

两种解决方案：
1. **扩展签名（推迟到后续计划）：** 将签名改为 `@Sendable (_ context: SkillPromptContext?) async -> String`，在 `SkillInvocationProcessor` 里传入。
2. **当前方案（本计划采用）：** Skillify prompt 让模型通过回顾对话历史（context window 中已有）自行分析，而不是在 prompt 文本中内嵌消息快照。这对 inline 执行模式是可行的，因为 inline skill 展开后模型能看到完整的对话历史。

### 为什么去掉 `disableModelInvocation: true`？

Claude Code 原版 skillify 设置 `disableModelInvocation: true` 是因为 ANT 内部环境只允许用户通过 `/skillify` slash 命令触发，不允许模型主动调用。agentGui 没有此限制，允许模型根据 `whenToUse` 提示自主触发，更符合 S-C1 的设计目标。

### `extractUserMessages` 是否需要处理多轮 tool-use 消息？

agentGui 的 `MessageParameter.Message` 中，`role == .user` 且 `content == .list` 的消息通常包含 tool result blocks，不是用户文本。当前 `extractUserMessages` 实现只提取 `.text` 类型 block，会自然跳过 tool result blocks（它们是 `.toolResult` 类型）。这与 Claude Code 的 `extractUserMessages` 行为一致。
