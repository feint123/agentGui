# ACP Composer Preferences Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 GitHub Copilot CLI 的 ACP 体验增加可扩展的会话级模型与审批模式切换，并让设置页与输入区共享一致的选择体系。

**Architecture:** 在 Session 上增加结构化的执行器偏好 JSON，由独立的 Codable 偏好模型承载 built-in 与 GitHub Copilot CLI 的会话级覆盖值。设置页继续维护全局默认值，输入区只写入当前会话偏好；执行前统一通过解析层合并全局默认值与会话覆盖，避免把 Claude 模型源误传给 Copilot。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Testing

---

### Task 1: 定义会话级执行器偏好模型

**Files:**
- Modify: `agentGui/Models/Session.swift`
- Create: `agentGui/Models/SessionExecutionPreferences.swift`
- Test: `agentGuiTests/SessionExecutionPreferencesTests.swift`

**Step 1: Write the failing test**

覆盖 built-in 模型回退、Copilot 模型覆盖、Copilot 审批模式覆盖。

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme agentGui -only-testing:agentGuiTests/SessionExecutionPreferencesTests`

**Step 3: Write minimal implementation**

新增 Session JSON 偏好字段与解析 helpers。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme agentGui -only-testing:agentGuiTests/SessionExecutionPreferencesTests`

### Task 2: 让 Copilot 执行链消费会话级覆盖

**Files:**
- Modify: `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Test: `agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: Write the failing test**

覆盖“会话级 model/approval override 优先于全局默认值”。

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme agentGui -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

**Step 3: Write minimal implementation**

让 provider 在 send 时合并 settings 与 session 偏好。

**Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme agentGui -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

### Task 3: 抽取可复用的执行器偏好选择控件

**Files:**
- Create: `agentGui/Views/GitHubCopilotComposerPreferencesView.swift`
- Modify: `agentGui/Views/Settings/SettingsExecutorsView.swift`
- Modify: `agentGui/Views/ChatView+InputArea.swift`
- Modify: `agentGui/Views/ChatView+Actions.swift`

**Step 1: 接入设置页默认值**

把 Copilot 模型改成下拉选择，把审批模式改成下拉选择。

**Step 2: 接入输入区会话值**

当执行器为 Copilot 时显示模型与审批模式选择；当执行器为 built-in 时显示 Claude 模型选择。

**Step 3: 保持最小耦合**

选择控件只依赖 Binding 与 catalog，不直接读写 SettingsStore 或 ChatView 状态。

### Task 4: 运行回归验证

**Files:**
- Test: `agentGuiTests/SessionExecutionPreferencesTests.swift`
- Test: `agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`

**Step 1: 运行针对性测试**

Run: `xcodebuild test -scheme agentGui -only-testing:agentGuiTests/SessionExecutionPreferencesTests -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests`

**Step 2: 运行质量烟测**

Run: `./scripts/run_quality_smoke.sh`