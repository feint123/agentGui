# Bug: Artifact 始终无法生成（执行结束后不写入 artifact board）

**日期**: 2026-03-31
**严重程度**: 高
**状态**: 已修复
**组件**: `ConversationExecutionOrchestrator`, `AgentTeamArtifactBoardCoordinator`, `AgentTeamSessionState`

## 问题描述

Team Workbench 的 Inspector 面板中，所有 task card 的 artifact 列表始终为空（显示"无工件"）。即使 team 执行完成，inspector 和 board 卡片也不会显示任何产物。这使 Feature 6（Typed Artifact Board）和 Feature 10（Review Gate）实际上完全失效。

## 复现步骤

1. 创建 Team session，填写 brief，启动 Team。
2. 等待 Working 卡片执行完成（状态变为 done 或手动点击"标记完成"）。
3. 察看 Inspector 面板和 Working/Done 列卡片上的 artifact 计数。

## 期望行为

执行完成后，inspector 应展示至少一个 artifact（如 `finalSynthesis`），卡片上应显示"1 件工件"而非"无工件"。

## 实际行为

inspector 始终显示"待选中 work item"或空 artifact 列表；卡片始终显示"无工件"。

## 根因分析

**完整的死路（dead end）**：`AgentTeamArtifactBoardCoordinator.submitArtifact()` 在整个运行时路径中从未被调用。

数据模型（`AgentTeamArtifact`）、协调层（`AgentTeamArtifactBoardCoordinator`）、持久化层（`AgentTeamSessionState.artifactBoardState`）和 UI（Inspector 面板）均已实现，但从执行流程到 artifact 写入的桥接代码完全缺失。

`ConversationExecutionOrchestrator.finish()` 的调用链：

```
finish(job:outcome:)
  ↓
persistenceStore.finish(...)
mailbox.finishRunning(...)
scheduler.markFinished(...)
projectionWriter.apply(.finished(...))
runtimeCoordinator.reconcileRuntimeRetention(...)
captureReviewArtifactsIfNeeded(...)   ← 只处理 workspace diff，无 team artifact 逻辑
dispatchReadyJobs()
```

`job.teamContext` 被正确传入 `ExecutionJob`，但在 `finish()` 时没有任何代码读取它、提取执行结果、并调用 `submitArtifact()` 写入 `session.agentTeamState.artifactBoardState`。

`AgentTeamArtifactBoardCoordinator` 和 `AgentTeamReviewCoordinator` 是纯函数服务层，只在单元测试中被调用，在生产运行时路径中完全悬空。

关键代码位置：
- [agentGui/Services/Execution/ConversationExecutionOrchestrator.swift](../../agentGui/Services/Execution/ConversationExecutionOrchestrator.swift)：`finish()` 方法缺少 team artifact 写入逻辑
- [agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift](../../agentGui/Services/Team/AgentTeamArtifactBoardCoordinator.swift)：`submitArtifact()` 生产路径调用点为零
- [agentGui/Models/AgentTeamSessionState.swift](../../agentGui/Models/AgentTeamSessionState.swift)：`artifactBoardState` 属性存在但从未被写入

## 修复思路

在 `ConversationExecutionOrchestrator.finish()` 中，判断 `job.teamContext != nil`，若为 team job，则：

1. 从 `session.messages` 中找到该 job 对应的最后一条 agent 消息（通过 `job.id` 或执行时间段匹配）
2. 将消息文本内容封装为 `AgentTeamArtifact(kind: .finalSynthesis, ...)`
3. 调用 `AgentTeamArtifactBoardCoordinator().submitArtifact()` 写入 artifact 到 `state.artifactBoardState`
4. 同时将 `artifactID` 链接到对应的 task card
5. 调用 `modelContext.save()`

这样能以最小成本打通 artifact 链路，后续再按 kind 细化（implementationPlan、patchProposal 等）。

## 受影响的功能

- Feature 6 Typed Artifact Board：Inspector artifact 列表始终为空
- Feature 10 Review Gate & Merge Gate：`AgentTeamMergeGateEvaluator` 要求 artifacts 存在才能通过，导致 Merge 按钮永远不可用

## 环境信息

- Swift 6, SwiftUI, SwiftData
- macOS
- agentGui, Feature 6 + Feature 10 实现
