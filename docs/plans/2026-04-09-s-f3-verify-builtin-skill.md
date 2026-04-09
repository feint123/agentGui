# S-F3: Verify 内置技能 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Claude Code 的 `verify` 工作流迁移为 agentGui 内置技能，让 built-in agent 接收到"验证某功能"的请求时，能依次执行 build → test → 手动确认，并将结果汇报给用户。

**Architecture:** 新增 `VerifySkill.swift`（位于 `agentGui/Services/BuiltInSkills/`）。对照 SkillifySkill 的注册模式，expose 一个 `registerVerifySkill(into:)` 函数，在 `agentGuiApp.init()` 中调用。Verify skill 采用 `executionContext: .inline`，prompt 模板硬编码在同文件，由 `$ARGUMENTS` 接收用户可选的功能描述。Claude Code 原版 `verify.ts` 是 ANT-only 保护的，agentGui 版去掉该 guard，并去掉 `examples/` 附加文件（agentGui 的内置技能无法像 bundledSkills.ts 那样做 Bun compile-time 文件嵌入）。

**Tech Stack:** Swift 6, SwiftUI，现有 `BuiltInSkillRegistry` / `BuiltInSkillDefinition` / `SkillInvocationProcessor` / `SkillArgumentSubstitution`

**依赖前置条件（已完成）:**
- S-F1: `BuiltInSkillRegistry` / `BuiltInSkillDefinition` 已在 `BuiltInSkillRegistry.swift` 中存在 ✅
- S-C1: `skill_invoke` 工具已在 `ClaudeService+ToolDispatch.swift` 中存在 ✅
- S-D1: `SkillArgumentSubstitution.substitute()` 已在 `SkillArgumentSubstitution.swift` 中存在 ✅
- `registerSkillifySkill()` 示范了正确的注册模式 ✅

---

## 参考：Claude Code 对标

| Claude Code (`verify.ts`) | agentGui 对应 |
|---|---|
| `registerBundledSkill({ name: 'verify', ... })` | `BuiltInSkillRegistry.shared.register(...)` |
| `userInvocable: true` | `userInvocable: true` |
| `files: SKILL_FILES`（`examples/cli.md` + `examples/server.md`）| **不迁移**：agentGui 无 Bun 文件嵌入，prompt 直接内联参考内容 |
| `process.env.USER_TYPE !== 'ant'` guard | **不迁移**：agentGui 无 USER_TYPE 概念 |
| `SKILL_BODY.trimStart()` + `## User Request\n\n${args}` | 同结构，用 Swift 字符串拼接 |
| frontmatter `description:`（动态从 SKILL.md 读取）| 硬编码常量 `verifyDescription` |

---

## 关键文件

| 路径 | 变更类型 |
|---|---|
| `agentGui/Services/BuiltInSkills/VerifySkill.swift` | **新建** — 注册函数 + prompt 模板 |
| `agentGui/agentGuiApp.swift` | **修改** — `init()` 中调用 `registerVerifySkill()` |
| `agentGuiTests/VerifySkillTests.swift` | **新建** — 单元测试 |

**不修改：**
- `BuiltInSkillRegistry.swift` — 注册机制已完备
- `SkillService.swift` — bundled skills 合并路径已完备
- `SkillInvocationProcessor.swift` — 调用链已完备
- `SkillArgumentSubstitution.swift` — `$ARGUMENTS` 替换已完备

---

## 设计决策

### 1. Verify prompt 的结构

verify 的 prompt 应指导模型按固定顺序执行验证流程，而不是自由发挥。核心步骤：

1. **Build** — 使用 `run_in_terminal` 执行 `xcodebuild build`（或根据检测到的项目类型调整）。
2. **Test** — 运行相关测试套件（`xcodebuild test` 或等效命令）。
3. **Manual check** — 用 `ask_user_question` 向用户确认关键交互是否符合预期。
4. **Report** — 总结 pass / fail 结果。

若 `$ARGUMENTS` 非空，将其作为 `## User Request` 追加，帮助模型聚焦到具体功能。

### 2. allowedTools

与 Claude Code verify 相同，不限制 `allowedTools`（空数组），让模型可以使用全部可用工具（build、读文件、问用户）。这避免了"模型发现需要读某个文件但权限被锁"的尴尬。若未来需要收紧，可在此补充白名单。

### 3. `executionContext: .inline`

verify 是一个交互式多步骤 skill，需要在主 agent 上下文中运行以便能 ask_user_question。不使用 fork。

### 4. `isEnabled`

不设置条件启用逻辑（`isEnabled = nil`），始终可用。与 SkillifySkill 保持一致。

---

## Verify Prompt 模板设计

```
# Verify $ARGUMENTS

You are verifying that a code change works correctly. Follow these steps **in order** — do not skip or rearrange them.

## Step 1: Build

Run a build to confirm the project compiles without errors.
- For Xcode projects: `xcodebuild build -scheme <scheme> -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- For Swift packages: `swift build`
- For other projects: detect the build tool (Makefile, cargo, go build, etc.) and use the appropriate command.

If the build fails, **stop and report the build error directly** — do not proceed to testing.

## Step 2: Run Tests

Run the relevant test suite.
- For Xcode projects: `xcodebuild test -scheme <scheme> -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- For Swift packages: `swift test`
- If the user request mentions a specific feature or file, try to identify and run only the related tests first.

If tests fail, **report which tests failed and the failure messages** — do not proceed to manual check.

## Step 3: Manual Verification

Use the `ask_user_question` tool to ask the user:

> "Build and tests passed. Please manually check the following and confirm:
> [List the 1-3 most important behaviors the user should verify based on their request and what you changed]
> Reply 'yes' if everything looks correct, or describe any issues you found."

## Step 4: Report

Summarize the verification result:
- ✅ **PASS** if all three steps succeeded.
- ❌ **FAIL** — describe which step failed and what the error or user report was.
```

---

## Task 1: 新建测试文件并写失败测试

**文件：** 新建 `agentGuiTests/VerifySkillTests.swift`

**Step 1: 写出测试骨架（编译会失败，因为 `registerVerifySkill` 不存在）**

```swift
// agentGuiTests/VerifySkillTests.swift
import XCTest
@testable import agentGui

final class VerifySkillTests: XCTestCase {

    private var registry: BuiltInSkillRegistry!

    override func setUp() {
        super.setUp()
        registry = BuiltInSkillRegistry()
        registerVerifySkill(into: registry)
    }

    override func tearDown() {
        registry.clearForTesting()
        registry = nil
        super.tearDown()
    }

    // MARK: - 注册验证

    func test_registration_skillAppearsInRegistry() {
        let skills = registry.allSkills()
        XCTAssertTrue(
            skills.contains(where: { $0.directoryName == "verify" }),
            "verify 应出现在 allSkills() 中"
        )
    }

    func test_registration_loadedFromBundled() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertEqual(skill.loadedFrom, .bundled)
    }

    func test_registration_userInvocableTrue() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertTrue(skill.userInvocable)
    }

    func test_registration_executionContextInline() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertEqual(skill.executionContext, .inline)
    }

    func test_registration_descriptionNonEmpty() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertFalse(skill.description.isEmpty, "description 不能为空")
    }

    func test_registration_whenToUseNonEmpty() {
        let skill = registry.allSkills().first(where: { $0.directoryName == "verify" })!
        XCTAssertNotNil(skill.whenToUse)
        XCTAssertFalse(skill.whenToUse!.isEmpty, "whenToUse 不能为空")
    }

    // MARK: - Prompt 内容验证

    func test_promptContent_noArgs_containsVerifyHeader() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Verify"),
            "prompt 应包含 'Verify' 标题"
        )
    }

    func test_promptContent_noArgs_containsBuildStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Build"),
            "prompt 应包含 Build 步骤说明"
        )
    }

    func test_promptContent_noArgs_containsTestStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Test"),
            "prompt 应包含 Test 步骤说明"
        )
    }

    func test_promptContent_noArgs_containsManualCheckStep() async {
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("Manual") || content!.contains("ask_user_question"),
            "prompt 应包含手动确认步骤"
        )
    }

    func test_promptContent_containsArgumentsPlaceholder() async {
        // $ARGUMENTS 占位符由 SkillArgumentSubstitution 在调用时替换；
        // prompt 模板本身应包含该占位符（以便替换机制生效）。
        let content = await registry.promptContent(skillName: "verify")
        XCTAssertNotNil(content)
        XCTAssertTrue(
            content!.contains("$ARGUMENTS"),
            "prompt 模板应包含 $ARGUMENTS 占位符"
        )
    }

    // MARK: - SkillArgumentSubstitution 集成验证

    func test_argumentSubstitution_replacesArgumentsPlaceholder() async {
        let rawContent = await registry.promptContent(skillName: "verify")!
        let syntheticDir = URL(fileURLWithPath: "/tmp")
        let result = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: "login flow",
            skillDirectory: syntheticDir,
            sessionId: "test-session"
        )
        XCTAssertFalse(
            result.contains("$ARGUMENTS"),
            "替换后不应再包含原始 $ARGUMENTS"
        )
        XCTAssertTrue(
            result.contains("login flow"),
            "替换后应包含传入的 args 内容"
        )
    }

    func test_argumentSubstitution_emptyArgs_leavesSilentlyEmpty() async {
        let rawContent = await registry.promptContent(skillName: "verify")!
        let syntheticDir = URL(fileURLWithPath: "/tmp")
        let result = SkillArgumentSubstitution.substitute(
            content: rawContent,
            args: nil,
            skillDirectory: syntheticDir,
            sessionId: "test-session"
        )
        // $ARGUMENTS 替换为空字符串时，prompt 应仍然合法可用
        XCTAssertFalse(result.isEmpty, "替换后内容不能为空")
    }
}
```

**Step 2: 确认测试无法编译（因为 `registerVerifySkill` 不存在）**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|VerifySkill"
```

预期：`error: use of unresolved identifier 'registerVerifySkill'`

**Step 3: 提交测试文件（红状态）**

```bash
git add agentGuiTests/VerifySkillTests.swift
git commit -m "test(s-f3): failing tests for verify built-in skill registration"
```

---

## Task 2: 实现 `VerifySkill.swift`

**文件：** 新建 `agentGui/Services/BuiltInSkills/VerifySkill.swift`

**Step 1: 创建文件**

```swift
//
//  VerifySkill.swift
//  agentGui
//

import Foundation

// MARK: - Registration

/// 将 verify 注册到指定的 `BuiltInSkillRegistry`（默认为 `.shared`）。
/// 在 `agentGuiApp.init()` 中调用一次。
///
/// 对应 Claude Code `src/skills/bundled/verify.ts` → `registerVerifySkill()`。
/// ANT-only guard (`process.env.USER_TYPE !== 'ant'`) 不迁移。
///
/// - Parameter registry: 注册目标，测试时传入独立实例。
func registerVerifySkill(into registry: BuiltInSkillRegistry = .shared) {
    registry.register(BuiltInSkillDefinition(
        name: "verify",
        description: verifyDescription,
        whenToUse: verifyWhenToUse,
        argumentHint: "[可选：描述要验证的功能或变更]",
        argumentNames: [],
        allowedTools: [],           // 不限制：verify 需要 build、read、ask_user_question 等
        model: nil,
        effort: nil,
        executionContext: .inline,  // 需要在主 agent 上下文中运行（ask_user_question）
        agent: nil,
        userInvocable: true,
        disableModelInvocation: false,
        version: "1.0",
        isEnabled: nil,             // 始终可用
        getPromptContent: { verifyPromptTemplate }
    ))
}

// MARK: - Metadata

private let verifyDescription =
    "Verify a code change does what it should: build, run tests, and confirm with the user."

private let verifyWhenToUse =
    "Use when the user asks to verify, check, or validate a feature or code change. " +
    "Examples: 'verify this works', 'check if the login flow is correct', 'validate my changes', 'run verify'."

// MARK: - Prompt Template

/// Verify 工作流 prompt 模板。
///
/// 对应 Claude Code `src/skills/bundled/verify.ts` → SKILL_BODY（从 SKILL.md 加载）。
/// agentGui 版无 Bun compile-time 文件嵌入，prompt 直接硬编码；
/// `examples/cli.md` 和 `examples/server.md` 的关键内容内联到步骤说明中。
///
/// 占位符：
/// - `$ARGUMENTS` — 调用时用户/模型传入的可选功能描述（由 SkillArgumentSubstitution 替换）
private let verifyPromptTemplate = """
# Verify $ARGUMENTS

You are verifying that a code change works correctly. Follow these steps **in order** — do not skip or rearrange them. Stop immediately if any step fails and report the error clearly.

## Step 1: Build

Run a build to confirm the project compiles without errors.

- **Xcode project** (`.xcodeproj` / `.xcworkspace`):
  ```
  xcodebuild build -scheme <scheme> -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  ```
- **Swift Package** (`Package.swift`):
  ```
  swift build
  ```
- **Other** (Makefile, Cargo, Go, etc.): detect and use the appropriate build command.

> If the build fails, **stop here** and report the build error. Do not proceed to Step 2.

## Step 2: Run Tests

Run the relevant test suite.

- **Xcode project**:
  ```
  xcodebuild test -scheme <scheme> -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  ```
  If the user request or `$ARGUMENTS` mentions a specific feature, identify the relevant test targets/suites and run only those first (faster feedback).
- **Swift Package**: `swift test`
- **Other**: detect and use the appropriate test command.

> If tests fail, **stop here** and report which tests failed and their failure messages. Do not proceed to Step 3.

## Step 3: Manual Verification

Use the `ask_user_question` tool to ask the user:

Compose the question based on what was asked in `$ARGUMENTS` (or infer from context). Include 1–3 specific behaviors the user should check. For example:

> "Build and all tests passed. Please manually verify the following, then reply 'yes' if correct or describe any issues:
>
> 1. [Key behavior 1 based on the change]
> 2. [Key behavior 2 if applicable]
> 3. [Key behavior 3 if applicable]"

Wait for the user's response before proceeding.

## Step 4: Report Result

Summarize the verification outcome:

- ✅ **PASS** — build succeeded, all tests passed, user confirmed correct behavior.
- ❌ **FAIL** — describe which step failed:
  - Build failure: paste the relevant error lines.
  - Test failure: list the failing test names and assertion messages.
  - User-reported issue: quote the user's description.
"""
```

**Step 2: 运行测试，验证测试通过**

```bash
cd /Volumes/T7/文稿/Projects/agentGui
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/VerifySkillTests \
  -derivedDataPath /tmp/agentGui-s-f3-verify \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：所有 `VerifySkillTests` 测试 **PASS**，`Executed N tests, with 0 failures`。

**Step 3: 提交实现文件**

```bash
git add agentGui/Services/BuiltInSkills/VerifySkill.swift
git commit -m "feat(s-f3): add verify built-in skill prompt template"
```

---

## Task 3: 在 `agentGuiApp` 中注册 Verify Skill

**文件：** 修改 `agentGui/agentGuiApp.swift`

**Step 1: 在 `init()` 中追加注册调用**

定位到 `init()` 方法，在 `registerSkillifySkill()` 之后添加：

```swift
init() {
    ConfigDirectoryManager.shared.setup()
    NSWindow.allowsAutomaticWindowTabbing = true
    // 注册内置技能（S-F1/S-F2）
    registerSkillifySkill()
    // S-F3: verify 内置技能
    registerVerifySkill()
}
```

**Step 2: 编译确认无错误**

```bash
xcodebuild build \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"
```

预期：`BUILD SUCCEEDED`，无任何 `error:`。

**Step 3: 追加端到端注册测试**

在 `agentGuiTests/VerifySkillTests.swift` 末尾添加测试，验证 `agentGuiApp.init()` 启动后 `.shared` registry 包含 verify：

> ⚠️ 此测试依赖全局 `BuiltInSkillRegistry.shared`。由于单测运行时不执行 `agentGuiApp.init()`，改为在 `setUp()` 时显式调用 `registerVerifySkill()` 注入到 `BuiltInSkillRegistry.shared`，然后测试后用 `clearForTesting()` 清理，避免测试间污染。

将以下测试追加到 `VerifySkillTests` 末尾：

```swift
// MARK: - 共享 Registry 集成

func test_sharedRegistry_registrationDoesNotCrash() {
    // 直接注册到 .shared，验证注册路径的完整性（测试后清理）
    let sharedRegistry = BuiltInSkillRegistry.shared
    registerVerifySkill(into: sharedRegistry)
    let skill = sharedRegistry.allSkills().first(where: { $0.directoryName == "verify" })
    XCTAssertNotNil(skill, "verify 应可成功注册到 BuiltInSkillRegistry.shared")
    sharedRegistry.clearForTesting()
}
```

**Step 4: 运行完整测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/VerifySkillTests \
  -derivedDataPath /tmp/agentGui-s-f3-verify \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部通过。

**Step 5: 提交**

```bash
git add agentGui/agentGuiApp.swift agentGuiTests/VerifySkillTests.swift
git commit -m "feat(s-f3): register verify skill in agentGuiApp.init()"
```

---

## Task 4: 补充边界测试

**文件：** 修改 `agentGuiTests/VerifySkillTests.swift`

这些测试覆盖 `SkillInvocationProcessor` 与 verify skill 的集成，确保调用链端到端有效。

**Step 1: 追加以下测试**

```swift
// MARK: - SkillInvocationProcessor 集成

func test_invocationProcessor_verifySkill_found() async {
    // 使用已注册 verify 的 registry 构造 MockProvider
    let provider = StubSkillContentProvider(registry: registry)
    let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
    let outcome = await processor.invoke(skillName: "verify", args: nil)
    guard case .success(let result) = outcome else {
        XCTFail("Expected success, got \(outcome)")
        return
    }
    XCTAssertEqual(result.commandName, "verify")
    XCTAssertFalse(result.content.isEmpty)
}

func test_invocationProcessor_verifySkill_withArgs_injectsArgs() async {
    let provider = StubSkillContentProvider(registry: registry)
    let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
    let outcome = await processor.invoke(skillName: "verify", args: "login flow")
    guard case .success(let result) = outcome else {
        XCTFail("Expected success, got \(outcome)")
        return
    }
    XCTAssertTrue(
        result.content.contains("login flow"),
        "content 应包含传入的 args 字符串"
    )
    XCTAssertFalse(
        result.content.contains("$ARGUMENTS"),
        "content 不应包含未替换的占位符"
    )
}

func test_invocationProcessor_verifySkill_noAllowedToolsRestriction() async {
    let provider = StubSkillContentProvider(registry: registry)
    let processor = SkillInvocationProcessor(provider: provider, sessionId: "test-session")
    let outcome = await processor.invoke(skillName: "verify", args: nil)
    guard case .success(let result) = outcome else {
        XCTFail("Expected success, got \(outcome)")
        return
    }
    XCTAssertTrue(
        result.allowedTools.isEmpty,
        "verify 不限制工具集，allowedTools 应为空"
    )
}
```

**Step 2: 确认 `StubSkillContentProvider` 是否已存在**

在项目中搜索：

```bash
grep -r "StubSkillContentProvider" /Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ 2>/dev/null
```

若存在，直接复用；若不存在，在 `VerifySkillTests.swift` 文件顶部（`final class` 之前）添加：

```swift
// MARK: - Test Helpers

/// SkillContentProviding 的测试替身，从 BuiltInSkillRegistry 中读取内容。
private struct StubSkillContentProvider: SkillContentProviding {
    let registry: BuiltInSkillRegistry

    func skillsList() async -> [Skill] {
        registry.allSkills()
    }

    func readSkillContent(name: String) async -> String? {
        await registry.promptContent(skillName: name)
    }
}
```

**Step 3: 运行补充测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/VerifySkillTests \
  -derivedDataPath /tmp/agentGui-s-f3-verify \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部通过，`0 failures`。

**Step 4: 提交**

```bash
git add agentGuiTests/VerifySkillTests.swift
git commit -m "test(s-f3): add SkillInvocationProcessor integration tests for verify skill"
```

---

## Task 5: 回归测试 — 确保已有测试不受影响

**Step 1: 运行 BuiltInSkillRegistry 现有测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/BuiltInSkillRegistryTests \
  -derivedDataPath /tmp/agentGui-s-f3-verify \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部通过。

**Step 2: 运行 SkillifySkill 测试**

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -only-testing:agentGuiTests/SkillifySkillTests \
  -derivedDataPath /tmp/agentGui-s-f3-verify \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "PASS|FAIL|error:|Executed"
```

预期：全部通过。

**Step 3: 最终提交**

```bash
git add -A
git commit -m "feat(s-f3): verify built-in skill - registration, prompt template, tests complete"
```

---

## 验收矩阵

| 验收标准 | 覆盖 Task | 验证方式 |
|---------|-----------|---------|
| `registerVerifySkill()` 编译可用 | Task 2 | xcodebuild build 无 error |
| verify 出现在 `allSkills()`，`loadedFrom == .bundled` | Task 1+2 | `test_registration_*` |
| `userInvocable: true`，`executionContext: .inline` | Task 1+2 | `test_registration_*` |
| prompt 模板包含 Build / Test / Manual 三步 | Task 1+2 | `test_promptContent_*` |
| `$ARGUMENTS` 占位符存在并被 `SkillArgumentSubstitution` 替换 | Task 1+4 | `test_argumentSubstitution_*` |
| `allowedTools` 为空（不限制工具集）| Task 4 | `test_invocationProcessor_verifySkill_noAllowedToolsRestriction` |
| `agentGuiApp.init()` 增加注册调用后编译通过 | Task 3 | xcodebuild build BUILD SUCCEEDED |
| 已有 BuiltInSkillRegistryTests / SkillifySkillTests 全部通过 | Task 5 | xcodebuild test |

---

## 范围边界（不实现）

- Claude Code `examples/cli.md` / `examples/server.md` 附加参考文件：agentGui 无 Bun compile-time 文件嵌入机制，CLI/server 场景的示例内容已内联到 prompt 步骤说明中，不需要额外文件。
- ANT-only guard：agentGui 无此概念，verify 对所有用户始终可用。
- `context: fork`：verify 需要 `ask_user_question` 与用户交互，必须在主 agent 上下文中内联运行。
- `VerificationEvidenceHook` 集成（设计文档中的 F-C4）：属于工具治理层特性，不在本 task 范围内。
