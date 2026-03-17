# Bash Tool

日期：2026-03-17

本文描述本仓库中已经落地的 Bash tool 行为，而不是 Anthropic 官方通用示例。

## 1. 当前定位

本项目的 Bash tool 已经不是“执行一条命令然后返回全部输出”的简单 shell 包装，而是一个受管 PTY 运行时，支持：

1. 任务级 `task_id` 生命周期管理。
2. attached / detached 两种执行模式。
3. 前台交互提示检测与自动回复。
4. Shell integration 语义增强。
5. 基于 terminal surface 的结构化交互规划。
6. UI 中的停止、规划中、等待批准、用户接管等状态投影。

## 2. 输入契约

当前推荐输入字段为：

1. `operation`
2. `command`
3. `task_id`
4. `execution_mode`
5. `input`
6. `timeout`
7. `force`
8. `tail_lines`

### 2.1 已支持的 `operation`

1. `start`
2. `sendInput`
3. `interrupt`
4. `terminate`
5. `status`
6. `readOutput`
7. `cleanup`

### 2.2 兼容行为

为了兼容旧调用路径，若输入只包含 `command` 而未提供 `operation`，系统会按隐式 `start` 处理。

这条兼容逻辑只用于保留旧 agent loop 行为；新调用应优先显式传递 `operation` 与 `task_id`。

### 2.3 已废弃的 legacy 字段

以下字段会被明确拒绝：

1. `background`
2. `interactive`
3. `interrupt`
4. `signal`
5. `goal_hint`
6. `scan_policy`
7. `auto_reply_policy`
8. `restart`

## 3. 运行时行为

### 3.1 前台任务

`execution_mode == attached` 时：

1. 使用 PTY 启动真实交互式进程。
2. 观测线程持续读取输出 tail。
3. 简单 prompt 先走 `BashPromptAnalyzer` fallback。
4. 若输出表现为菜单/TUI 屏幕，则进入 surface extraction + planner 分流。
5. 非终态期间 UI 一直保留停止按钮。

### 3.2 后台任务

`execution_mode == detached` 时：

1. 运行时返回 task snapshot。
2. transcript 写入任务日志。
3. 后续通过 `status` / `readOutput` / `cleanup` 查询和回收。

## 4. Fallback prompt analyzer 范围

`BashPromptAnalyzer` 当前只负责低成本、低歧义场景：

1. package-manager 安装确认。
2. 常规 yes/no prompt。
3. `press enter to continue`。
4. 密码输入。
5. 覆盖/删除等破坏性确认。

它不负责菜单式交互，不承担复杂 TUI 理解。

## 5. Terminal planner 行为

当输出被 `TerminalSurfaceExtractor` 识别为单选、多选或文本输入屏幕时：

1. runtime 构建 `TerminalSurfaceSnapshot`。
2. planner 输出结构化 `TerminalInteractionPlan`。
3. host 根据 `confidence` 与 `requiresUserConfirmation` 决定自动执行还是等待批准。
4. planner 决策与动作历史会写入 `TerminalTaskEvent`。

当前自动执行阈值为：

1. `requiresUserConfirmation == false`
2. `confidence >= 0.8`

否则任务进入 `awaitingUserApproval`。

## 6. UI 状态

当前 UI 已支持以下受管终端状态：

1. `启动中`
2. `执行中`
3. `等待输入`
4. `规划中`
5. `等待批准`
6. `用户接管`
7. `已完成`
8. `失败`
9. `已中断`
10. `已超时`
11. `已终止`

同时 `ToolCall` 会记录：

1. `terminalTaskId`
2. `terminalTaskStatus`
3. `terminalInteractionPhase`
4. `terminalPlannerSummary`
5. `terminalApprovalPending`
6. `terminalUserTakeoverActive`
7. `terminalAgentActionsJSON`
8. `terminalTranscriptPath`
9. `terminalCompletionReason`

## 7. Shell integration 语义增强

当前 runtime 已支持解析 `OSC 633` 的以下事件：

1. prompt start / end
2. command start
3. command finished + exit code
4. command line
5. cwd property

这些事件会回写到 `TerminalTaskSnapshot`，用于改进：

1. 当前工作目录显示。
2. 命令边界识别。
3. planner 输入压缩。
4. 终端任务事件审计。

## 8. 当前限制

截至 2026-03-17，仍有以下限制：

1. planner 还是 deterministic fallback contract，尚未接入真实 LLM planner。
2. 批准 / 接管的状态和展示已经落地，但完整的人机接管闭环还在继续收口。
3. end-to-end interactive fixture 已开始抽象，但覆盖面还未达到所有安装器和 REPL 场景。

## 9. 测试覆盖

当前相关测试覆盖以下层次：

1. `TerminalTaskModelsTests`
2. `TerminalKeyEncoderTests`
3. `TerminalSurfaceExtractorTests`
4. `TerminalShellIntegrationParserTests`
5. `TerminalTaskRuntimeTests`
6. `BashPromptAnalyzerTests`
7. `TerminalInteractionPlannerTests`
8. `BashToolCallPresentationTests`
9. `AgentLoopIntegrationTests`

后续若继续扩展复杂交互能力，应优先补 fixture 和集成测试，再改 planner 或 runtime 行为。