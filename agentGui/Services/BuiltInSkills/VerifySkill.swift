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
