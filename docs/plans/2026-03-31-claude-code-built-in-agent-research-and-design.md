# Claude Code 仓库调研与 agentGui 内置 Agent 增强设计

日期：2026-03-31

## 1. 结论先行

这次调研最重要的结论不是“我找到了 Claude Code 当前主分支里的完整 prompt 和 agent 内核”，而是相反：当前公开的 instructkr/claude-code 仓库主分支已经不再保留那套实现源码，现有可直接验证的内容主要是一个 Python porting workspace、少量工作流元信息，以及对 OmX 工作模式的说明。因此，这份文档必须把“可验证事实”和“设计性推断”严格分开。

在可验证范围内，能够稳定提炼出来、且对 agentGui 当前内置 Agent 真正有价值的，并不是第三方 prompt 文本本身，而是三类更高层的设计信号：

1. 把“研究/并行评审”和“持续执行/完成纪律”分成显式 operating mode，而不是只靠一个主系统提示词硬扛全部职责。
2. 把 agent 的完成标准从“模型说 done”提升为“计划、执行证据、验证 frontier、收尾结论”四段式闭环。
3. 把多代理协作从普通聊天文本流中剥离，转成受约束的角色、能力切片、结构化产物和 review gate。

agentGui 其实已经具备其中相当多的骨架：主 loop、子代理、计划工具、验证工具、工具授权、ACP provider、Team Workbench 都已经存在。真正缺的不是“再抄一套 Claude Code prompt”，而是把这些分散能力收束成更明确的运行模式、角色边界和收尾纪律。

因此，本设计文档的核心建议是：不要把目标定义为“复制 instructkr/claude-code 的 prompt”，而应定义为“把 agentGui 现有能力重组为更强的研究模式、执行模式和团队控制面”。

## 2. 证据边界

### 2.1 可直接验证的外部事实

直接网页和仓库内容显示，instructkr/claude-code 当前主分支已经转为 Python-first workspace：

- 仓库主页与 README 明确写明，主内容现在是 Python porting workspace，而不是原始 exposed TypeScript snapshot。
- README 明确说明，作者最初研究过 exposed codebase 的 harness、tool wiring 和 agent workflow，但后来不希望继续把那个 snapshot 作为主跟踪源码。
- 当前公开 src 目录主要是 Python 侧的 manifest、backlog、summary/query engine，以及一个极小的 task 数据结构。
- README 的“Built with oh-my-codex”部分仅暴露了两个工作模式线索：$team 和 $ralph。

直接证据来源：

- https://github.com/instructkr/claude-code
- https://raw.githubusercontent.com/instructkr/claude-code/main/README.md

### 2.2 无法直接验证的内容

当前公开主分支中，无法直接提取以下内容：

1. 原始 Claude Code 主系统 prompt。
2. 原始工具 schema 与调度实现。
3. 原始 slash command prompt。
4. 原始计划器、执行器、验证器之间的对话协议。
5. 原始 session/runtime 恢复策略的实现代码。

因此，任何“Claude Code 的具体 prompt 长什么样”之类的说法，在当前证据下都不应当被当作事实。

### 2.3 这份文档采用的方法

本报告把信息分为三层：

1. 直接证据：来自 instructkr/claude-code 当前公开内容，或 agentGui 当前仓库代码。
2. 合理推断：由 OmX 工作模式命名、README 描述和 agentGui 已有架构共同推导出的设计趋势。
3. 设计建议：面向 agentGui 的可实现增强方案，不宣称来自对方仓库的逐字实现。

## 3. 对 instructkr/claude-code 当前仓库的实际观察

### 3.1 当前仓库已不适合做“源码级 prompt 提取”

当前外部仓库的主价值，不在于现成代码，而在于它公开留下了一个非常清楚的转向信号：

1. 从“研究 exposed codebase”转向“独立重写与工作流方法”。
2. 从“原始实现细节”转向“任务组织方式与开发 discipline”。
3. 从“单次问答”转向“团队式 review + 持续执行 + 完成校验”的工作流组合。

这意味着，对 agentGui 来说，真正值得吸收的不是某段具体 prompt，而是 operating model。

### 3.2 当前可提炼的外部设计信号

#### A. Team mode

README 明确提到 $team mode 用于 coordinated parallel review and architectural feedback。这说明外部工作流至少强调：

1. 多角色并行审视同一任务。
2. review 与 architecture feedback 被视作一等工作，不是实现后的附属动作。
3. 团队协作应当有明确的工作面，而不是单代理在一个 prompt 里假装多角色。

#### B. Ralph mode

README 明确提到 $ralph mode 用于 persistent execution, verification, and completion discipline。这条信息非常关键，因为它对应的不是“更会写代码”，而是：

1. 执行要持续，不因一次回答就中断。
2. 验证是独立环节。
3. 完成有纪律，不允许未证实地宣称 done。

#### C. Workspace summarization

当前 Python src 中的 manifest、commands、tools、query_engine 虽然很简单，但透露了一种思路：

1. 把工作空间能力面显式建模。
2. 把命令面、工具面、模块面做成可枚举对象，而不是散落在代码里。
3. 为 agent 提供 summary surface，而不是每轮都临时从零搜索。

这对 agentGui 的启发不是“照搬 Python 文件”，而是应该补强内置 Agent 的 workspace manifest 与 capability summary 层。

## 4. agentGui 当前基线

对照当前仓库，agentGui 已经拥有比外部公开仓库更强、也更完整的本地基础设施。

### 4.1 已有能力

#### A. 主系统提示与运行时上下文

主系统提示已经显式注入：

- 当前时间、时区、locale、操作系统、主机名、工作目录。
- 子代理编排规则。
- 复杂任务的 planning protocol。
- verify 与 completion claim 的纪律。

关键位置：

- [agentGui/Services/ClaudeService/ClaudeService+Prompting.swift](../../agentGui/Services/ClaudeService/ClaudeService+Prompting.swift)

#### B. 主循环与工具执行协调

agentGui 已实现较完整的 agentic loop，包括：

- 多轮 streaming round。
- 工具执行协调器。
- 权限审批。
- tool result payload budget 与大结果引用。
- 执行证据与 verify state 相关状态。

关键位置：

- [agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift](../../agentGui/Services/ClaudeService/ClaudeService+AgenticLoop.swift)
- [agentGui/Services/AgentLoopRunner.swift](../../agentGui/Services/AgentLoopRunner.swift)
- [agentGui/Services/AgentLoopRoundExecutor.swift](../../agentGui/Services/AgentLoopRoundExecutor.swift)
- [agentGui/Services/AgentLoopToolExecutionCoordinator.swift](../../agentGui/Services/AgentLoopToolExecutionCoordinator.swift)

#### C. 计划、Todo 与验证闭环

当前内置工具已经有：

- create_execution_plan
- update_todo_list
- verify_completion

关键位置：

- [agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift](../../agentGui/Services/ClaudeService/ClaudeService+ToolBuilder.swift)
- [agentGui/Services/ClaudeService/ClaudeService+ExecutionPlan.swift](../../agentGui/Services/ClaudeService/ClaudeService+ExecutionPlan.swift)
- [agentGui/Services/ClaudeService/ClaudeService+TodoTool.swift](../../agentGui/Services/ClaudeService/ClaudeService+TodoTool.swift)

#### D. 子代理与角色定义

当前系统已经有基于文档驱动的 explore、worker、verifier 三类 built-in 子代理，并带有 tool grant 和 output contract。

关键位置：

- [agentGui/Resources/Agents/explore.agent.md](../../agentGui/Resources/Agents/explore.agent.md)
- [agentGui/Resources/Agents/worker.agent.md](../../agentGui/Resources/Agents/worker.agent.md)
- [agentGui/Resources/Agents/verifier.agent.md](../../agentGui/Resources/Agents/verifier.agent.md)
- [agentGui/Models/AgentRuntimeDefinition.swift](../../agentGui/Models/AgentRuntimeDefinition.swift)
- [agentGui/Models/WorkflowRoleDefinition.swift](../../agentGui/Models/WorkflowRoleDefinition.swift)

#### E. 工具授权与能力切片

当前已经存在 ToolRegistry、ToolAuthorizationResolver、tool grant、context-based authorization。说明 agentGui 已经具备“角色化工具切片”的基础能力。

关键位置：

- [agentGui/Services/ToolRegistry.swift](../../agentGui/Services/ToolRegistry.swift)
- [agentGui/Services/ToolAuthorizationResolver.swift](../../agentGui/Services/ToolAuthorizationResolver.swift)

#### F. Team Workbench 与结构化 Team 状态

agentGui 已经不是只有单对话 Agent，它已经有：

- AgentTeamMissionBrief
- Team launch / claim / review / artifact board
- Team Workbench UI
- Team execution gate

关键位置：

- [agentGui/Models/AgentTeamMissionBrief.swift](../../agentGui/Models/AgentTeamMissionBrief.swift)
- [agentGui/Models/AgentTeamSessionState.swift](../../agentGui/Models/AgentTeamSessionState.swift)
- [agentGui/Services/Team/AgentTeamLaunchCoordinator.swift](../../agentGui/Services/Team/AgentTeamLaunchCoordinator.swift)
- [agentGui/Services/Team/AgentTeamClaimExecutionGate.swift](../../agentGui/Services/Team/AgentTeamClaimExecutionGate.swift)
- [agentGui/Services/Team/AgentTeamReviewCoordinator.swift](../../agentGui/Services/Team/AgentTeamReviewCoordinator.swift)
- [agentGui/Views/Team/AgentTeamSessionView.swift](../../agentGui/Views/Team/AgentTeamSessionView.swift)

### 4.2 已有但不完整

#### A. Team 控制面还不够“真 conductor”

当前 Team Workbench 已经有不错骨架，但 conductor 还没有成为真正的 planning/scheduling control plane。现有仓库自身也已经把这一点记录成 bug 与后续 feature。

关键证据：

- [docs/bug/2026-03-31-agent-team-conductor-no-scheduling.md](../bug/2026-03-31-agent-team-conductor-no-scheduling.md)
- [docs/plans/2026-03-30-acp-agent-team-design.md](2026-03-30-acp-agent-team-design.md)

#### B. Slash command 主要承载 skill 与 ACP 远端命令

当前 slash command 已经支持：

- 技能激活
- ACP provider 广告出来的远端命令

但还没有把“本地运行模式切换”做成一等 slash surface，例如 /research、/team、/ship、/verify、/ralph 之类的内置模式命令。

关键位置：

- [agentGui/Services/SlashCommandRegistry.swift](../../agentGui/Services/SlashCommandRegistry.swift)
- [agentGui/Services/ChatInputCommandParser.swift](../../agentGui/Services/ChatInputCommandParser.swift)
- [agentGui/Views/ChatView+InputArea.swift](../../agentGui/Views/ChatView+InputArea.swift)

#### C. 完成纪律是“可用能力”，但还不是“主运行模式”

当前系统 prompt 已经要求复杂任务要计划、验证、总结，但这仍更像一套 general policy，而不是用户可见、可切换、可强制的执行模式。换句话说，agentGui 已经有 Ralph 所需的零件，但还没有“Ralph mode”。

### 4.3 明显缺失

1. 没有一个显式的 built-in operating mode 概念，把研究、执行、团队、验证收尾当作产品级模式暴露。
2. 没有内置 workspace manifest / command surface / tool surface summary 工具，导致主 Agent 仍偏向每轮临时探索。
3. 没有把 verifier-style frontier ranking 提升为主 loop 的默认收尾关卡。
4. 没有把 Team conductor 的 planning 结果变成结构化卡片生成主链。
5. 没有本地内置 slash presets 来切换 prompt profile、tool ceiling、max rounds、verification strictness。

## 5. 差距判断：真正值得从外部信号中吸收什么

### 5.1 不建议做的事情

1. 不建议追逐“还原 Claude Code 原 prompt 原文”。当前公开仓库没有这份证据，而且逐字复制也没有产品护城河。
2. 不建议再加一个笼统的 mega system prompt，把所有纪律继续堆到主提示里。
3. 不建议把 Team mode 退化成多个 provider 顺序说话的 message 流。

### 5.2 建议做的事情

1. 把运行模式显式产品化。
2. 把完成纪律从“提醒”升级成“控制面”。
3. 把 Team conductor 真正做成 planning/scheduling agent。
4. 把 workspace summary 做成内置工具，而不是完全依赖子代理搜索。
5. 把 slash command 从“技能入口”扩展为“运行模式入口”。

## 6. 建议方案：为 agentGui 引入四种内置运行模式

### 6.1 Mode 1: Standard

目标：保持当前默认体验。

特征：

1. 主 Agent 直接响应。
2. 复杂任务按现有 protocol 可计划、可子代理、可验证。
3. 适合日常问答与轻量修改。

### 6.2 Mode 2: Research

目标：把外部 README 中体现的 team/review 取向，落为“先取证再综合”的主模式。

行为：

1. 强制先跑 explore。
2. 如有多个候选方向，再并行调用 explore 多次，分别采集不同来源或不同代码域。
3. 主 Agent 只负责综合，不直接在无证据时下结论。

适合：

1. 技术调研
2. 架构比较
3. 外部项目研究
4. 长文档总结

### 6.3 Mode 3: Execution Discipline

这是建议落地的 Ralph 对应模式。

目标：把 persistent execution、verification、completion discipline 变成显式模式。

行为：

1. 复杂任务开头强制 create_execution_plan。
2. 执行中强制 update_todo_list 持续同步。
3. 收尾前强制 verify_completion。
4. 若存在高影响未验证 claim，则自动调用 verifier 子代理做 frontier ranking。
5. 若 frontier 未关闭，禁止主 Agent 使用“已完成”措辞。

适合：

1. 多文件实现
2. bugfix
3. 需要跑测试或命令的任务
4. 高风险改动

### 6.4 Mode 4: Team Control Plane

目标：把当前 Team Workbench 从 UI 骨架推进到真正的 conductor-driven 协作控制面。

行为：

1. conductor 先产出结构化 task breakdown。
2. task card 再进入 claim / dispatch。
3. reviewer 与 merge gate 成为发布前显式环节。
4. 主聊天只接收 final synthesis，不承载完整协作过程。

## 7. 建议方案：新增内置 slash 运行模式命令

当前 slash command 主要是技能和 ACP 远端命令。建议新增本地命令层，把“模式切换”放到用户可见界面中。

建议新增：

1. /research
2. /execute
3. /verify
4. /team
5. /ship

### 7.1 语义

#### /research

- 激活 Research mode
- 提高 web/search 与 read-only discovery 倾向
- 默认先 explore 后综合

#### /execute

- 激活 Execution Discipline mode
- 默认强制 plan + todo + verify
- 提高对子代理 worker 的使用倾向

#### /verify

- 当前任务进入 verifier-first 收尾
- 聚焦未证实 claim、残余风险和下一探针

#### /team

- 创建或切入 Team Workbench 工作流
- 触发 conductor planning，再进入 claim/disptach

#### /ship

- 在 verify completion 与 review frontier 足够关闭时，执行最终总结与发布

## 8. 建议方案：新增 Workspace Manifest 工具层

这是当前外部 Python workspace 最值得借鉴的一个小但高价值的点。

### 8.1 问题

当前主 Agent 每轮都在做这些事情：

1. 重新了解工作区结构
2. 重新推断关键模块
3. 重新推断可用命令和工具面

这会导致：

1. token 浪费
2. 早期规划不稳定
3. 研究任务的第一轮经常只是“先搜一遍仓库”

### 8.2 建议新增

建议为内置 Agent 增加一个只读 summary 工具，至少返回：

1. workspace root
2. 关键顶层目录
3. 语言与构建系统
4. 可运行任务列表
5. agent 相关核心模块
6. 最近一次已知 quality gate 名称

可命名为：

- workspace_manifest
- workspace_capability_summary

### 8.3 预期收益

1. 主 Agent 在复杂任务开头可先拿一份低成本全局画像。
2. Research mode 可减少机械搜索。
3. Team conductor 能更稳定地拆分任务卡。

## 9. 建议方案：把 verifier 升格为主收尾关卡

当前 verifier 已经存在，但更多是“主 Agent 想用时可调用”。建议改成模式化行为。

### 9.1 建议规则

满足以下任一条件时，Execution Discipline mode 在收尾前自动调用 verifier：

1. 改动文件数 >= 3
2. 运行过 shell / test / build
3. 用户请求包含 修复、重构、实现、验证、review
4. 任务涉及外部 provider、ACP 或 Team workbench

### 9.2 verifier 输出需要服务于 host runtime

建议 verifier 输出结构至少包括：

1. supported_claims
2. unsupported_claims
3. highest_risk_gap
4. cheapest_next_probe
5. residual_risks

这样它可以直接喂给现有的 verify_completion 记录，而不是只返回自然语言段落。

## 10. 建议方案：让 Team conductor 真正产出结构化计划

这部分是当前 agentGui 最值得优先补强的地方，因为你已经有 Team Workbench，但 conductor 还没有真正成为调度器。

### 10.1 当前问题

当前 design 与 bug 文档已经说明：

1. conductor 在启动时更多只是 preferred provider 标签。
2. mission brief 仍会被打平成 prompt 直接发给 provider。
3. task card 不是由 planning 结果驱动。

### 10.2 建议主链

1. launch team
2. conductor planning job
3. conductor 返回 JSON task breakdown
4. 系统解析为 task cards
5. cards 进入 claim / dispatch
6. reviewer / merge gate 收敛

### 10.3 建议输出结构

建议 conductor planning 输出至少包含：

1. card title
2. goal
3. dependency ids
4. required capabilities
5. expected artifact kinds
6. recommended provider role
7. validation notes

### 10.4 与现有代码的最小接入点

最小改造入口：

1. [agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift](../../agentGui/Services/Team/AgentTeamMissionPromptBuilder.swift)
2. [agentGui/Services/Team/AgentTeamLaunchCoordinator.swift](../../agentGui/Services/Team/AgentTeamLaunchCoordinator.swift)
3. [agentGui/Models/AgentTeamSessionState.swift](../../agentGui/Models/AgentTeamSessionState.swift)
4. [agentGui/Views/Team/AgentTeamSessionView.swift](../../agentGui/Views/Team/AgentTeamSessionView.swift)

## 11. 建议方案：Prompt 设计重构

这一节给出的不是“从外部仓库提取出的原 prompt”，而是结合外部可验证工作流信号与 agentGui 当前架构后，为你当前 built-in agent 设计的 prompt 草案。

### 11.1 主 Agent Prompt 补强方向

当前主 prompt 已经很好，但建议新增两类显式约束：

1. operating mode 指令块
2. completion discipline 指令块

建议新增段落：

#### Operating Mode

如果当前会话被标记为 Research mode：

- 默认先收集证据，再下结论。
- 优先使用 explore 子代理或只读工具，而不是直接作答。
- 若外部事实不可确认，明确标记为未证实。

如果当前会话被标记为 Execution Discipline mode：

- 对复杂任务必须先记录计划。
- 必须保持 todo 状态与实际执行同步。
- 在声称完成之前，必须列出已验证和未验证项。
- 若高影响 claim 缺乏证据，优先调用 verifier。

#### Completion Discipline

- 不得把“应该可行”表述成“已验证”。
- 不得把未运行的命令、未观察到的测试结果、未读取的文件状态当作事实。
- 若存在未关闭的高影响验证缺口，结尾必须明确指出，而不是用完成语气掩盖。

### 11.2 Research 子代理 Prompt 草案

当前 explore 已经接近正确方向，但还可以更强地服务“报告输出”。建议增加：

1. findings 必须区分 direct evidence 与 inference。
2. 对外部仓库研究任务，先判断“目标实现是否仍公开存在”。
3. 如果不存在，立即切换为“evidence boundary report”而不是继续装作找到了源码。

### 11.3 Worker 子代理 Prompt 草案

建议新增：

1. 对多文件变更必须先列读到的关键文件。
2. 对高风险工具调用，执行前先确认验证计划。
3. 收尾输出必须包含“实际观察到的验证证据”。

### 11.4 Verifier 子代理 Prompt 草案

建议新增：

1. 明确要求把 unsupported claims 单独列出。
2. 明确要求给出 cheapest next probe。
3. 明确要求区分 local evidence 与 external fact gap。

## 12. 优先级建议

### P0

1. 引入 Execution Discipline mode。
2. 给主系统 prompt 增加 operating mode 与 completion discipline 段。
3. 让 verifier 成为复杂实现任务的默认收尾关卡。

### P1

1. 新增内置 slash 运行模式命令。
2. 新增 workspace manifest / capability summary 工具。
3. 把 Team conductor planning 变成结构化主链。

### P2

1. 为 Team mode 增加更细粒度 capability slice。
2. 为不同 mode 暴露不同默认 tool ceiling 与 round budget。
3. 把 review/merge frontier 更明确地投影到 Workbench UI。

## 13. 推荐落地顺序

### Phase 1: 把 Ralph 做成产品能力

目标：不大改架构，先把“执行纪律”变成显式模式。

包含：

1. AppSettings / Session 新增 agent operating mode。
2. 主系统 prompt 根据 mode 注入不同约束。
3. Execution Discipline mode 自动启用 create_execution_plan、todo 同步和 verifier-first 收尾。

### Phase 2: 把 slash 变成模式入口

包含：

1. /research
2. /execute
3. /verify
4. /team
5. /ship

### Phase 3: 把 Team conductor 做实

包含：

1. conductor planning prompt
2. 结构化 task breakdown 解析
3. 自动生成 task cards
4. reviewer / merge gate 强化

### Phase 4: 引入 Workspace Manifest

包含：

1. 仓库能力面摘要工具
2. 任务和命令面摘要
3. 供主 Agent 与 conductor 优先调用

## 14. 最终判断

如果把这次调研总结成一句话：

当前 instructkr/claude-code 公开主分支已经不足以支持“源码级 prompt 提取”，但它留下的工作流信号非常明确，而这些信号与你当前 agentGui 的方向高度契合。

真正应该吸收的不是外部仓库某一版 prompt 文本，而是以下设计原则：

1. 研究应先取证后综合。
2. 执行应有持续性、验证和完成纪律。
3. 团队协作应建立在结构化控制面之上。
4. 运行模式应该是产品概念，而不是藏在系统 prompt 里的隐含状态。

从产品成熟度角度看，agentGui 现在离“更强的 built-in agent”其实只差一步：把已经存在的零件，重组成显式 mode system 和更强的 conductor control plane。

这比试图复刻一个当前已经不公开的第三方 prompt，更有确定性，也更能形成你自己的体系。