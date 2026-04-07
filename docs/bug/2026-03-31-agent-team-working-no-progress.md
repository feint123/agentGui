# Bug: Working 状态下无任何执行进度信息

**日期**: 2026-03-31
**严重程度**: 中
**状态**: 已修复
**组件**: `AgentTeamSessionView`, `AgentTeamWorkbenchPanelViews`, `ExecutionProjection`

## 问题描述

Team Workbench 中，当 task card 进入 Working 状态后，UI 上没有任何信息反映执行进度。用户无法判断 provider 是否在执行、执行到哪个阶段、是否卡住。

这违反了设计文档第 12.3 节 Workstream Board 的要求："展示 parallel progress"，以及 Team Roster 要展示"当前 card"和"readiness"。

## 复现步骤

1. 创建 Team session，填写 brief，启动 Team。
2. 等待卡片进入 Working 列。
3. 观察 UI 是否有流式内容、phase 旗帜、工具调用进度等信息。

## 期望行为

Working 卡片下方应展示实时执行状态，例如：
- 当前执行 phase（thinking / tool_use / responding）
- streaming 文本摘要或 token 进度指示
- 正在调用的工具名称

## 实际行为

Working 卡片仅显示一个静态的"状态：Working"文字标签，无任何动态信息。

## 根因分析

`AgentTeamSessionView` 完全没有接入 `ExecutionProjection` 订阅层。

`ChatView` 通过 `ChatMessageListProjectionModel` 实时渲染 streaming 内容、phase ribbon、工具调用泡泡等。`AgentTeamSessionView` 对 `claudeService` 的执行状态没有任何观察，`AgentTeamBoardPanelView` / `AgentTeamBoardCardView` 的数据全部来自静态的 `AgentTeamWorkbenchPresentation`，后者只读取 SwiftData 持久化状态，不读取实时投影。

关键代码位置：
- [agentGui/Views/Team/AgentTeamSessionView.swift](../../agentGui/Views/Team/AgentTeamSessionView.swift)：无任何 `ExecutionProjection` 订阅
- [agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift](../../agentGui/Views/Team/AgentTeamWorkbenchPanelViews.swift)：`AgentTeamBoardCardView` 数据来源为静态 presentation
- [agentGui/Views/ChatView.swift](../../agentGui/Views/ChatView.swift)：对比参考，正确使用了投影层

## 修复思路

在 `AgentTeamSessionView` 中读取当前 team session 的 `ExecutionProjection`（`claudeService.executionOrchestrator.projectionStore.projection(for: session.sessionId)`），并将其传入 `AgentTeamBoardPanelView`。

在 Working 列的 `AgentTeamBoardCardView` 下方，当 `projection.isRunning == true` 时渲染一个轻量进度区：
- 复用 `ExecutionPhaseRibbonView` 或等效的 phase 标签
- 或显示"执行中…"加 indeterminate `ProgressView`

不需要完整复制 ChatView 的消息列表，只需让用户感知到"provider 正在工作"及当前阶段。

## 环境信息

- Swift 6, SwiftUI, SwiftData
- macOS
- agentGui, Feature 5 Task Card Board 实现
