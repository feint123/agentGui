# Bug: Conductor 无实质调度行为，仅作为标签存在

**日期**: 2026-03-31
**严重程度**: 低
**状态**: 已归档为 Feature 13
**组件**: `AgentTeamMissionPromptBuilder`, `AgentTeamLaunchCoordinator`, `AgentTeamWorkbenchPresentation`

## 问题描述

Team Workbench 的 Team Roster 中可以看到"conductor"角色条目，但用户完全感受不到 conductor 在做任何调度工作。conductor 的行为与直接让 provider 单独执行任务没有区别，看不出"生成 brief、创建 task cards、分配 ownership"等设计中规定的 conductor 职责。

## 复现步骤

1. 创建 Team session，使用任意支持 ACP 的 provider 作为 conductor。
2. 启动 Team，观察 conductor 的行为和 UI 展示。
3. 对比单 provider 普通 chat session，感知是否有差异。

## 期望行为

根据设计文档第 7.1 节，conductor 应承担控制面职责：
- 根据 brief 生成 task cards（而非 brief 直接打包成一个 prompt 发出去）
- 调度哪个 provider 认领哪张卡
- 在执行中触发 replan / merge

Roster 面板的 conductor 条目各字段（readiness、focus、blocker）应反映实际调度状态，而不是硬编码字符串。

## 实际行为

- `AgentTeamMissionPromptBuilder.buildPrompt()` 把 objective + constraints + acceptance criteria 全部打包成一段 prompt，直接发给 conductor 执行，没有任何"conductor 分配任务"阶段
- conductor 的执行走的是普通 session 执行路径，其回复不会被解析为 task card 更新
- Roster 面板的 readiness/focus 字段是硬编码字符串（"负责 brief、claim 决策与调度"），不反映运行时状态

## 根因分析

当前实现把 conductor 定义为"auto-claim 时使用的那个 provider reference"，没有独立的 conductor 执行阶段。

`AgentTeamLaunchCoordinator.launch()` 的逻辑：
1. 取 `brief.providerPlan.preferredConductor`
2. 为其创建 auto-claim
3. 生成一段 `missionPrompt`（把所有 brief 信息打平）
4. 调 `sendMessage()` 让 conductor 执行

这等价于"把整个任务发给一个 provider 做"，不是"conductor 协调多个 provider 分工"。

关键代码位置：
- [agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift](../../agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift)：`buildPrompt()` 直接打平 brief
- [agentGui/Services/Team/AgentTeamLaunchCoordinator.swift](../../agentGui/Services/Team/AgentTeamLaunchCoordinator.swift)：conductor 只是 auto-claim 的 provider 标签
- [agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift](../../agentGui/ViewModels/AgentTeamWorkbenchPresentation.swift)：Roster conductor/worker/reviewer readiness 字段均为硬编码

## 修复思路

**短期（改善可观测性，不改底层架构）：**

1. `AgentTeamWorkbenchPresentation` 的 Roster conductor 条目：`readiness` 改为反映实际 `claimBoardState`（有无 accepted claim），`focus` 改为当前 working card 的 title。
2. Prompt 中加入明确的 conductor 角色说明，告知 provider 它是 conductor，负责产出结构化执行计划。

**中期（conductor 真正产出 task card）：**

3. 在 `AgentTeamMissionPromptBuilder` 中为 conductor 生成专用 prompt，要求 conductor 回复 JSON 格式的 task breakdown，由 UI 层解析并生成子 task cards。
4. 增加 conductor planning 阶段，在该阶段结束前不启动 worker dispatch。

## 环境信息

- Swift 6, SwiftUI, SwiftData
- macOS
- agentGui, Feature 3/4/5 实现
