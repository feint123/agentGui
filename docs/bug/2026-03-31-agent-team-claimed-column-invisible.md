# Bug: Claimed 列永远为空，briefed 直接跳到 working

**日期**: 2026-03-31
**严重程度**: 中
**状态**: 已修复
**组件**: `AgentTeamLaunchCoordinator`, `ClaudeService+TeamDispatch`, `AgentTeamWorkbenchPresentation`

## 问题描述

Team Workbench 的 Workstream Board 中，"Claimed"列永远没有任何 task card。用户点击"启动 Team"后，卡片从 Briefed 直接出现在 Working 列，Claimed 中间态对用户完全不可见。

这违反了 Feature 4 验收标准第 2 条："UI 能显示谁认领了什么"，以及 Brief-Claim-Commit 协议中 Claim 阶段应对用户可解释的要求。

## 复现步骤

1. 创建一个 Team session，填写 mission brief。
2. 点击"启动 Team"按钮。
3. 观察 Workstream Board 的各列。

## 期望行为

点击启动后，卡片应短暂出现在"Claimed"列（显示认领的 provider），之后才进入"Working"状态。

## 实际行为

卡片直接出现在"Working"列，"Claimed"列始终为空。

## 根因分析

`AgentTeamLaunchCoordinator.launch()` 在一次同步调用中依次执行：

```
.briefed → acceptBestClaim() → .claimed → transitionCard(.working) → .working
```

三次状态转换在同一个 `launch()` 内串行完成，`modelContext.save()` 在 `ClaudeService.launchTeamMission()` 中只在 `launch()` 返回之后才执行一次。因此 SwiftUI 从未观察到 `.claimed` 中间状态，Claimed 列永远为空。

关键代码位置：
- [agentGui/Services/Team/AgentTeamLaunchCoordinator.swift](../../agentGui/Services/Team/AgentTeamLaunchCoordinator.swift)：`launch()` 方法，第 44–120 行
- [agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift](../../agentGui/Services/ClaudeService/ClaudeService+TeamDispatch.swift)：`launchTeamMission()` 方法

## 修复思路

在 `ClaudeService.launchTeamMission()` 中，把 launch 拆成两步：

1. 第一步：只执行到 `.claimed`（auto-claim + acceptBestClaim），save + `Task.yield()`，让 SwiftUI 渲染一帧 Claimed 状态。
2. 一个短暂延迟（可用 `Task.sleep` 约 300–500ms）后，执行 `.working` 转换，再 save，再 `sendMessage()`。

或者拆分 `AgentTeamLaunchCoordinator.launch()` 为 `claimCard()` 和 `beginWorking()` 两个独立方法，由 `launchTeamMission()` 分两次异步调用。

## 环境信息

- Swift 6, SwiftUI, SwiftData
- macOS
- agentGui, Feature 4 实现（auto-claim 路径）
