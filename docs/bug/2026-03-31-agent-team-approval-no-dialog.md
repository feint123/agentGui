# Bug: Provider 请求 approval 时 Team Workbench 无法响应

**日期**: 2026-03-31
**严重程度**: 高
**状态**: 已修复
**组件**: `AgentTeamSessionView`, `ClaudeService+AskUserQuestion`

## 问题描述

当 team session 下的 ACP provider（OpenCode、Claude Code 等）在执行中触发 `ask_user_question` 工具（用于请求用户审批或确认）时，Team Workbench 没有弹出任何交互界面，执行被永久挂起，用户无法响应，也无法让 provider 继续执行。

## 复现步骤

1. 创建 Team session，选择需要审批的 ACP provider（如 OpenCode，默认非 auto-approve 模式）。
2. 启动 Team，让 provider 执行一个会触发审批请求的任务（如写文件、运行命令）。
3. 观察 Team Workbench 是否有审批弹窗。

## 期望行为

执行过程中，当 provider 需要用户确认时，Team Workbench 应弹出 `AskUserQuestionView`（与 ChatView 中相同的结构化选项对话框），用户确认后执行继续。

## 实际行为

没有任何弹窗出现。`claudeService.pendingUserQuestion(for: session.sessionId)` 有值，但没有任何视图订阅它并呈现 `AskUserQuestionView`，导致审批请求永久挂起，执行卡死在 team session 中。

## 根因分析

`AskUserQuestionView` 的 sheet wiring 只存在于 `ChatView`：

```swift
// ChatView.swift，约第 136–146 行
.sheet(item: Binding(
    get: { claudeService.pendingUserQuestion(for: session.sessionId) },
    set: { newVal in
        if newVal == nil {
            claudeService.pendingUserQuestion(for: session.sessionId)?.cancel()
            claudeService.clearPendingUserQuestion(for: session.sessionId)
        }
    }
)) { request in
    AskUserQuestionView(request: request)
}
```

`AgentTeamSessionView` 完全没有对等的 `.sheet(item:)` modifier，也没有其他任何展示 pending user question 的机制。

关键代码位置：
- [agentGui/Views/Team/AgentTeamSessionView.swift](../../agentGui/Views/Team/AgentTeamSessionView.swift)：缺少 `AskUserQuestionView` 的 sheet wiring（需新增）
- [agentGui/Views/ChatView.swift](../../agentGui/Views/ChatView.swift)：第 136–146 行，正确实现的参考
- [agentGui/Services/ClaudeService/ClaudeService+AskUserQuestion.swift](../../agentGui/Services/ClaudeService/ClaudeService+AskUserQuestion.swift)：`publishPendingUserQuestion()` 写入到 session-scoped 状态

## 修复思路

在 `AgentTeamSessionView.body` 上添加与 `ChatView` 完全对等的 `.sheet(item:)` modifier：

```swift
.sheet(item: Binding(
    get: { claudeService.pendingUserQuestion(for: session.sessionId) },
    set: { newVal in
        if newVal == nil {
            claudeService.pendingUserQuestion(for: session.sessionId)?.cancel()
            claudeService.clearPendingUserQuestion(for: session.sessionId)
        }
    }
)) { request in
    AskUserQuestionView(request: request)
}
```

该修复是纯 View 层改动，不需要修改任何服务层代码，改动范围极小。

## 环境信息

- Swift 6, SwiftUI, SwiftData
- macOS
- agentGui, Team Workbench + ACP provider 审批机制
