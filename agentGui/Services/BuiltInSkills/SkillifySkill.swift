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
            guard msg.role == "user" else { return nil }
            let text: String
            switch msg.content {
            case .text(let t):
                text = t
            case .list(let blocks):
                text = blocks.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
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
