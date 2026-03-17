# 2026-03-16 Bash 复杂交互编排技术方案

日期：2026-03-16

关联对象：`BashPromptAnalyzer`、`TerminalTaskRuntime`、`PtyProcessController`、`ClaudeService+BashTool`、`AgentLoopToolExecutionCoordinatorBuilder`、终端任务 UI

关联文档：

- `docs/technical-spec/2026-03-16-bash-runtime-hardening.md`
- `docs/bash tool.md`
- `docs/archive/spec/2026-03-10-bash-tool-redesign-requirements.md`

## 0. 当前实施状态（2026-03-17）

当前实现已经完成以下部分：

1. `TerminalSurfaceSnapshot`、`TerminalInteractionAction`、`TerminalInteractionPlan` 等交互模型已落地。
2. `TerminalKeyEncoder` 已支持 `enter`、`space`、`tab` 与方向键 ANSI 序列。
3. `TerminalSurfaceExtractor` 已能从 `create-vue` 风格屏幕中提取可见选项、选择模式与 alternate screen 标志。
4. `TerminalShellIntegrationParser` 已支持 `OSC 633` 的 cwd、command line、prompt 与命令完成事件。
5. `TerminalTaskRuntime` 已支持 shell integration 语义入库与结构化交互动作回放。
6. `BashPromptAnalyzer` 已缩回低成本 fallback，仅保留 yes/no、安装确认、密码、破坏性确认、press-enter。
7. `AgentLoopToolExecutionCoordinatorBuilder` 已接入基于 surface 的 planner 分流，并把 planner 决策写入 terminal task events。
8. `ToolCall`、气泡头部、详情视图、行展示已支持规划中、等待批准、用户接管等状态投影。

当前仍保留以下约束：

1. planner 仍是 deterministic fallback contract，尚未接入真实 LLM planner。
2. “等待批准”和“用户接管”状态已经能投影到 UI，但完整的人机批准/接管操作链路还需要继续收口。
3. 复杂交互的 end-to-end fixture 目前已开始抽成共享测试支撑，但覆盖面还在扩展中。

## 0.1 已落地的 planner contract

当前 planner 输入为：

1. 用户目标或当前命令摘要。
2. 当前命令文本。
3. `TerminalSurfaceSnapshot`。
4. 最近一帧 plain-text 输出。

当前 planner 输出为结构化 `TerminalInteractionPlan`，包含：

1. `interactionType`
2. `intentSummary`
3. `confidence`
4. `nextActions`
5. `requiresUserConfirmation`
6. `reasoningSummary`

Host 侧当前判定规则为：

1. `requiresUserConfirmation == false` 且 `confidence >= 0.8` 时自动执行。
2. 其余情况进入 `awaitingUserApproval`，等待用户批准或后续接管链路。

## 0.2 已落地的 approval / takeover 语义

当前 UI 和状态模型已支持以下交互阶段：

1. `planning`
2. `autoExecuting`
3. `awaitingApproval`
4. `userTakeover`

对应终端任务状态已扩展为：

1. `planningInteraction`
2. `awaitingUserApproval`
3. `userTakeover`

当前 UI 保证：

1. 非终态任务始终保留 stop 按钮。
2. 等待批准时展示 planner 摘要与“需要批准”标记。
3. 用户接管时展示“用户接管”阶段与 planner 暂停摘要。

## 0.3 Fallback analyzer 的边界

当前 `BashPromptAnalyzer` 只负责低成本 prompt fallback：

1. package-manager 安装确认。
2. 常规 yes/no prompt。
3. `press enter to continue`。
4. 密码输入 prompt。
5. 破坏性覆盖/删除确认。

它明确不负责：

1. 菜单识别。
2. 多选导航。
3. 光标移动语义。
4. 任意 TUI 屏幕理解。

## 0.4 Shell integration 依赖说明

当前复杂交互编排已经开始依赖 shell integration 语义增强，但仍保留降级能力：

1. 若能读到 `OSC 633`，runtime 会记录 cwd、command line 与退出事件。
2. 若没有 shell integration，系统仍可依赖 PTY transcript + surface extraction + fallback analyzer 工作。
3. Shell integration 是增强层，不是运行前置条件。

## 1. 问题定义

当前 Bash tool 已经具备以下基础能力：

1. PTY 运行时。
2. 任务级 `task_id` 生命周期管理。
3. 基本 prompt 检测。
4. 简单 yes/no 自动回复。
5. 手动停止按钮与 `interrupt` 控制。

但它仍然无法可靠处理 `npm create vue` / `create-next-app` / 安装器向导 / REPL / TUI 菜单等复杂交互式命令。

典型失败样例不是单个 yes/no 提示，而是这种多轮结构化终端会话：

1. 标题与说明文本。
2. 单选题。
3. 多选题。
4. 光标移动与选中态渲染。
5. 回车提交当前屏幕。
6. 进入下一屏继续交互。

`create-vue` 的行为本质上不是“普通命令 + 一次确认”，而是一个基于 ANSI/TTY 的小型终端应用。

因此，问题不该表述为“把 `BashPromptAnalyzer` 再写复杂一点”，而应表述为：

**如何把 Bash tool 从“文本 prompt 规则匹配器”升级为“受管终端交互编排器”。**

## 2. 现状评估

### 2.1 当前实现的长处

当前架构已经做对了三件重要的事：

1. 采用 PTY，而不是 `Pipe` 假装终端。
2. 建立了任务级状态机，而不是把 shell 当成单一黑盒。
3. 将运行时状态投影到 `ToolCall` 和 UI，可以表达“运行中 / 等待输入 / 已终止”。

这意味着系统已经具备升级到更强交互模型的基础。

### 2.2 当前实现的结构性短板

当前 `BashPromptAnalyzer` 的输入是“当前输出全文字符串”，输出是“简单 prompt 决策”。这套模型有四个天然上限：

1. 它只理解文本，不理解终端控制序列、光标位置、alternate screen、checkbox、焦点项。
2. 它把交互理解为“识别一个提示句，然后回复一行文本”，不适合多轮菜单式交互。
3. 它没有区分“命令生命周期事件”和“终端表面渲染状态”。
4. 它没有使用 LLM 做状态理解与动作规划，只做了传统规则判断。

因此它对下面几类任务会系统性失效：

1. `npm create vue` / `pnpm create` 这类向导。
2. `git add -p` / `git rebase -i` 这类交互式 CLI。
3. 带全屏布局的 TUI 程序。
4. 多轮问答式安装器。
5. REPL 与命令补全型交互。

## 3. 外部方案调研结论

### 3.1 VS Code 的公开做法

VS Code 公开文档说明，它的终端智能能力并不是主要依赖正则猜测，而是依赖 shell integration 注入的结构化语义：

1. 命令开始。
2. 命令结束。
3. 退出码。
4. 当前工作目录。
5. 明确的命令行边界。
6. 命令检测质量等级。

文档还公开了 `OSC 633` / `OSC 133` / `OSC 1337` 这类 shell integration 序列支持。这说明成熟产品的共识是：

**不要仅靠终端文本表面去猜发生了什么，而要尽量让 shell/terminal 主动上报结构化状态。**

这对本项目的直接启发是：

1. `BashPromptAnalyzer` 应该退化为保底 heuristics，而不是主干能力。
2. 主干能力应建立在 shell integration、VT 序列解析、任务状态机和 LLM 规划之上。

### 3.2 优秀产品的共同模式

虽然不同产品公开细节不同，但成熟终端/agent 产品普遍共享以下模式：

1. **任务块化**：不是把终端看成一坨滚动文本，而是看成命令块、状态块、输出块、交互块。
2. **语义增强**：工作目录、退出码、命令边界、失败原因由 shell integration 或 runtime 提供。
3. **多层决策**：简单问题由规则快速处理，复杂问题才升级到智能决策层。
4. **可视中断**：任何长任务都必须允许用户显式停止或接管。
5. **人机协作降级**：当系统不确定当前屏幕含义时，不能继续瞎按，而应该请求用户确认或接管。

## 4. 推荐方案

推荐采用 **Hybrid Terminal Orchestration**：

1. **Shell Integration Layer** 负责命令边界和环境语义。
2. **Terminal State Extraction Layer** 负责把 PTY 字节流还原为更接近“屏幕状态”的结构。
3. **Policy Layer** 负责廉价、确定性的快速路径。
4. **LLM Interaction Planner** 负责复杂屏幕理解和下一步动作决策。
5. **Human Override Layer** 负责中断、接管、批准和恢复。

不推荐继续扩大 `BashPromptAnalyzer` 的正则和关键字表，原因是这会让系统越来越像传统 expect 脚本，复杂度上升但泛化能力仍然很差。

## 5. 目标架构

### 5.1 Layer A: Shell Integration

为 `zsh` / `bash` 注入 shell integration，优先获取：

1. prompt start / end。
2. pre-exec / post-exec。
3. exit code。
4. cwd。
5. command line。

这层解决的问题是：

1. 当前命令边界不再靠猜。
2. 任务开始和结束时机更可靠。
3. UI 可以准确显示命令块和输出块。
4. LLM 不必从整段 transcript 猜“哪一段是本轮命令输出”。

建议兼容：

1. VS Code `OSC 633` 风格。
2. FinalTerm/iTerm 兼容序列作为降级路径。

### 5.2 Layer B: Terminal Surface Model

新增一个 `TerminalSurfaceSnapshot`，它不是简单的全文日志，而是“当前终端屏幕”的抽象。

建议字段：

1. `plainTextFrame`
2. `cursorRow`
3. `cursorColumn`
4. `isAlternateScreen`
5. `visibleOptions`
6. `focusedOptionIndex`
7. `selectionMode`
8. `inputHint`
9. `rawANSISnippet`

这里不要求第一版就完整实现 VT100 模拟器，但至少要做到：

1. 识别 alternate screen。
2. 识别光标移动。
3. 识别常见菜单项前缀，比如 `◇`、`◆`、`◻`、`◼`、`>`。
4. 从最后一帧中提取可见选项列表和当前焦点候选。

这一步完成后，系统面对 `create-vue` 时看到的就不再是“一大段日志”，而是“当前屏幕包含一个单选题或多选题”。

### 5.3 Layer C: Prompt / Interaction Policy Engine

保留并重构 `BashPromptAnalyzer`，但角色从“唯一交互引擎”改成“快速策略层”。

它负责：

1. `yes/no`。
2. `press enter`。
3. password。
4. destructive confirmation。
5. package-manager safe install prompts。

它不再负责：

1. 多选菜单。
2. 光标导航。
3. 向导式表单。
4. TUI 布局理解。

换句话说，Policy Engine 只处理低成本、高置信、低风险场景。

### 5.4 Layer D: LLM Interaction Planner

这是本次建议的核心升级。

新增一个专用 planner，对复杂终端状态执行以下任务：

1. 识别当前交互类型。
2. 从用户目标推断应该选择什么。
3. 规划下一步键盘动作序列。
4. 判断是否需要用户确认。
5. 在每一步之后复盘新屏幕并继续。

planner 的输入不应该是完整原始 transcript，而应是压缩过的结构化上下文，例如：

1. 用户任务目标。
2. 当前命令。
3. 当前 `TerminalSurfaceSnapshot`。
4. 最近 20 行输出。
5. 已执行动作历史。
6. 风险级别。

planner 的输出建议不是自由文本，而是结构化动作：

```json
{
  "interaction_type": "multi_select_menu",
  "intent_summary": "create-vue feature selection",
  "confidence": 0.88,
  "next_actions": [
    {"type": "move", "key": "down", "count": 1},
    {"type": "toggle", "key": "space"},
    {"type": "submit", "key": "enter"}
  ],
  "requires_user_confirmation": false,
  "reasoning_summary": "User asked for TypeScript + JSX + Router + Pinia + Vitest; current screen is feature multi-select"
}
```

### 5.5 Layer E: Human Override

UI 层必须始终保留：

1. 停止按钮。
2. 继续等待按钮。
3. 手动输入入口。
4. 接管当前终端会话的能力。

复杂交互并不意味着“让 LLM 一路自动按到底”。正确做法是：

1. 高置信、低风险自动推进。
2. 中置信场景请求用户批准。
3. 低置信、高风险场景直接等待用户接管。

## 6. 为什么这是更通用、也更 LLM-native 的方案

### 6.1 规则系统的问题

传统规则系统的基本模式是：

1. 看一句文本。
2. 匹配关键字。
3. 决定回什么字符。

它适合 `Proceed? [y/N]`，不适合 `create-vue` 这种终端 UI。因为真正的交互语义不在单句文本里，而在：

1. 屏幕布局。
2. 焦点位置。
3. 被勾选项。
4. 用户目标与当前状态之间的关系。

### 6.2 LLM 的真正用法

这里的 LLM 不该只是“更大的正则”。它应该承担的是：

1. **状态理解**：当前屏幕是什么类型。
2. **目标映射**：用户需求如何映射到选项组合。
3. **动作规划**：接下来按哪些键。
4. **不确定性管理**：什么时候停止自动化并请求用户确认。

这比单纯在 `BashPromptAnalyzer` 增加 if/else 更符合 LLM 的能力边界。

## 7. 推荐的状态机

建议把终端任务状态扩展为：

1. `launching`
2. `running`
3. `waitingForInput`
4. `planningInteraction`
5. `awaitingUserApproval`
6. `userTakeover`
7. `completed`
8. `failed`
9. `interrupted`
10. `timedOut`

其中：

1. `waitingForInput` 表示 runtime 发现命令正在等待交互。
2. `planningInteraction` 表示正在调用 planner 分析当前屏幕。
3. `awaitingUserApproval` 表示 planner 有候选方案但需要用户确认。
4. `userTakeover` 表示用户接管当前任务。

## 8. 建议的动作模型

不要把交互动作只建模为 `send_input(String)`。

建议新增：

1. `text("...")`
2. `key("enter")`
3. `key("space")`
4. `key("tab")`
5. `key("up")`
6. `key("down")`
7. `key("left")`
8. `key("right")`
9. `signal("interrupt")`
10. `wait(milliseconds)`

原因很直接：TUI 菜单不是靠输入一整行文本完成，而是靠离散按键序列完成。

## 9. 建议的数据与组件新增

### 9.1 新模型

建议新增：

1. `TerminalSurfaceSnapshot`
2. `TerminalInteractionPlan`
3. `TerminalInteractionAction`
4. `TerminalInteractionObservation`

### 9.2 新服务

建议新增：

1. `TerminalSurfaceExtractor`
2. `TerminalInteractionPlanner`
3. `TerminalInteractionCoordinator`
4. `TerminalActionEncoder`

### 9.3 现有组件职责调整

`BashPromptAnalyzer`：

1. 保留。
2. 只做低成本 prompt heuristics。
3. 不再承担复杂交互主逻辑。

`AgentLoopToolExecutionCoordinatorBuilder`：

1. 保留观测线程。
2. 增加 planner 调度和动作回放。
3. 不再只做 prompt 标记。

`ToolCall` / 终端任务 UI：

1. 增加当前交互阶段展示。
2. 展示 planner 决策摘要。
3. 支持批准 / 拒绝 / 接管。

## 10. 迭代路线

### Phase 1: 语义底座

目标：让 runtime 能可靠知道“命令边界、cwd、exit code、当前屏幕是否进入复杂交互”。

任务：

1. 引入 shell integration 事件采集。
2. 增加 `TerminalSurfaceSnapshot`。
3. 识别 alternate screen 和常见菜单视觉特征。
4. 保留当前 prompt analyzer 作为 fallback。

验收：

1. `create-vue` 当前屏幕可被识别为 `single_select` / `multi_select` 类型。
2. UI 能显示当前屏幕摘要，而不只是原始日志。

### Phase 2: LLM Planner

目标：复杂交互从“规则匹配”升级到“状态理解 + 动作规划”。

任务：

1. 实现 `TerminalInteractionPlanner`。
2. 定义结构化 planner 输入输出。
3. 加入安全门控：高风险动作需要批准。
4. 记录 planner 决策到 terminal events。

验收：

1. `npm create vue` 可自动走完至少一轮单选和一轮多选。
2. planner 决策可在 UI 中查看。

### Phase 3: Human-in-the-loop

目标：自动化和人工接管之间形成稳定协作链路。

任务：

1. 增加“批准本轮计划”UI。
2. 增加“手动输入 / 手动导航 / 接管终端”能力。
3. 增加失败恢复与继续执行能力。

验收：

1. 用户可以在复杂交互中随时接管。
2. 接管结束后可以还给 agent 继续。

### Phase 4: 泛化与评测

目标：建立真正可演进的交互能力，而不是一个只支持 `create-vue` 的特例。

任务：

1. 建立 interactive command fixture 集。
2. 覆盖 package installers、git patch flows、REPL、TUI 菜单。
3. 新增自动评测：成功率、步数、人工介入率、误操作率。

## 11. 测试策略

建议新增四层测试：

1. `BashPromptAnalyzerTests`
   继续覆盖低级 prompt 规则。
2. `TerminalSurfaceExtractorTests`
   用 ANSI 片段回放验证屏幕状态提取。
3. `TerminalInteractionPlannerTests`
   用固定 surface snapshot 验证 planner 输出动作。
4. `AgentLoopIntegrationTests`
   覆盖 `create-vue`、`git add -p`、password prompt、destructive confirmation 等完整链路。

不要把复杂交互能力的测试全部压在 analyzer 层，否则会继续把系统推回“传统脚本规则引擎”。

## 12. 最终建议

结论很明确：

1. `BashPromptAnalyzer` 应保留，但只能当 fallback policy，不应继续扩张成主系统。
2. 更通用的方向不是写更多 prompt 规则，而是建立 **shell integration + terminal surface model + LLM planner + human override** 的混合架构。
3. 第一优先级不是支持更多字符串模式，而是让系统能表达“当前终端屏幕状态”。
4. 第二优先级才是让 LLM 根据屏幕状态规划键盘动作。
5. UI 必须始终允许用户停止、批准、接管。

如果这个方向成立，后续实现计划应以“终端交互编排器”命名，而不是继续围绕 `BashPromptAnalyzer` 做局部增强。