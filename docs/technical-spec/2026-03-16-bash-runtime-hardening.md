# 2026-03-16 Bash Runtime PTY 重构技术方案

日期：2026-03-16

关联对象：`ClaudeService+BashTool`、`TerminalTaskSnapshot`、`BashTaskRegistry`、`ToolCall`、终端任务 UI、后续 PTY Runtime 实现

关联文档：

- `docs/bash tool.md`
- `docs/archive/spec/2026-03-10-bash-tool-redesign-requirements.md`

## 1. 结论

本次需求调整后，Bash Runtime 不再做“基于 `Process + Pipe + sentinel` 的增量加固”，而是直接切换为 **PTY-only** 方案。

新方案采用以下硬约束：

1. 所有 bash 任务都运行在 PTY 之上，不再保留 Pipe/Sentinel 前台执行路径。
2. 不做兼容层设计，不要求保留旧字段、旧状态机语义、旧交互兜底。
3. 历史 runtime 可以删除，只保留迁移所需的最小 UI / 数据承接。
4. `task_id` 作为唯一任务主键，所有继续输入、终止、读取输出、查询状态都必须显式路由。
5. 前台、交互式、后台长任务统一为同一套 PTY 任务模型，不再拆成两套执行语义。

这意味着当前文档中的“先补结构化 outcome、后补后台控制面、最后收紧 task_id”三阶段策略作废，改为直接定义新的 PTY Runtime。

## 2. 为什么要彻底重写

旧方案的问题不是“少几个状态字段”，而是底层抽象已经不对。

当前 `BashSession` 以单一持久 shell + `Pipe` 读写为核心，这会带来结构性限制：

1. 终端程序是否需要 TTY 无法从根上满足，`vim`、`less`、`ssh`、交互安装器、彩色输出、行编辑、全屏程序都天然不可靠。
2. 完成态依赖 sentinel 文本，而不是依赖 PTY 会话和子进程真实退出事件。
3. “交互命令”和“后台任务”只能靠补丁式逻辑叠加，无法共享统一生命周期。
4. 单一持久 shell 让任务路由天然模糊，控制操作很容易错误落到“当前活动命令”。

如果继续在旧模型上加字段，本质上仍然是在错误抽象上增加复杂度。需求既然已经明确为“完全切换到 PTY”，就不应该再为旧实现支付兼容成本。

## 3. 新范围定义

本方案的目标不是“让旧 BashTool 更稳一点”，而是把 BashTool 改造成 **受管 PTY 任务运行时**。

本次必须达成的范围：

1. 每个任务拥有独立 PTY 会话。
2. Runtime 可以创建、持续观察、写入输入、发送信号、读取输出、清理任务。
3. `ToolExecutionResult` 和 `ToolCall` 基于结构化任务结果，而不是基于输出文本猜测成功失败。
4. UI 展示基于任务状态和 PTY transcript，而不是基于旧 BashSession 文本快照。
5. 后台长任务继续受管，可查询状态、读取最近输出、终止和清理。

明确不在本次范围内的事项：

1. 不保留旧 `background`、`interactive`、`interrupt` 输入兼容层。
2. 不保留旧 `BashSession` 的持久 shell 复用模型。
3. 不做双轨运行时，不允许新旧实现并存。
4. 不做“尽量兼容旧测试”，测试应按新语义重写。

## 4. 核心设计原则

### 4.1 每个任务一个 PTY

每次 `start` 都创建一个新的 PTY 任务，而不是在同一个持久 shell 中串行执行多条命令。

好处：

1. 任务隔离明确，不共享错误的 shell 上下文。
2. `task_id` 与 PTY 会话一一对应，控制语义简单。
3. 后台任务不再依赖“主 shell 仍然活着”。
4. 交互式程序、REPL、安装器与普通命令走同一套输入输出通道。

代价：

1. 不再提供跨命令共享 shell 状态的假象。
2. 需要显式传递工作目录、环境变量和启动参数。

这个代价是可接受的，因为它换来的是真正可维护的任务语义。

### 4.2 任务而不是命令行文本才是一等对象

新 Runtime 的一等实体是 `TerminalTask`，不是“一段命令字符串”。

每个任务必须具备：

1. 稳定 ID。
2. PTY master/slave 生命周期。
3. 子进程 PID / 进程组 ID。
4. 输出缓冲与日志落盘。
5. 结构化完成态。
6. 可控制的任务操作集合。

### 4.3 控制必须显式路由

新方案下不存在“默认当前命令”。任何控制类调用都必须带 `task_id`。

以下操作必须显式指定目标：

1. `send_input`
2. `interrupt`
3. `terminate`
4. `status`
5. `read_output`
6. `cleanup`

找不到任务、任务已结束、任务状态不允许该操作时，都必须返回结构化错误。

## 5. 新运行时架构

推荐将 PTY Runtime 划分为五层。

### 5.1 PtyProcessController

底层 PTY 控制器，负责：

1. 创建 PTY master/slave。
2. fork/exec 启动 shell 或目标命令。
3. 维护子进程 PID 与进程组。
4. 从 PTY 读取输出流。
5. 向 PTY 写入输入。
6. 发送 `SIGINT`、`SIGTERM`、必要时 `SIGKILL`。
7. 监听进程退出并生成原始退出结果。

这是新的底座，取代当前 `BashSession`。

### 5.2 TerminalTaskRuntime

面向上层的任务运行时，负责：

1. 创建任务。
2. 保存任务与 PTY 控制器之间的映射。
3. 聚合实时输出。
4. 生成状态迁移。
5. 处理超时、清理和异常恢复。

它是所有 bash tool 操作的统一入口。

### 5.3 TerminalTaskRegistry

受管任务快照中心，负责：

1. 持久化最新任务快照。
2. 记录事件时间线。
3. 为 UI / ToolCall / 审计层提供只读视图。

现有 `BashTaskRegistry` 可以保留名字或重命名，但语义必须改成 PTY task registry，而不是旧 BashSession 辅助对象。

### 5.4 TerminalTranscriptStore

专门负责输出持久化：

1. 内存缓冲最近输出。
2. 按任务写入 transcript / log 文件。
3. 支持读取最近 N 行或从 offset 增量读取。

后台任务与前台任务都走同一套 transcript 存储，不再分叉处理。

### 5.5 BashToolOperationRouter

负责把工具请求映射到运行时操作：

1. 校验请求。
2. 根据 `operation` 和 `task_id` 路由。
3. 返回结构化结果给 `ToolExecutionResult`。

现有 `ClaudeService+BashTool` 中与兼容字段归一化相关的大量逻辑应删除，只保留新 schema 解析与调用编排。

## 6. 数据模型

### 6.1 TerminalTaskSnapshot

建议至少包含以下字段：

1. `id: String`
2. `sessionId: String`
3. `command: String`
4. `status: TerminalTaskStatus`
5. `executionMode: TerminalExecutionMode`
6. `workingDirectory: String?`
7. `environmentSummary: [String: String]?`
8. `pid: Int32?`
9. `processGroupID: Int32?`
10. `startedAt: Date?`
11. `endedAt: Date?`
12. `exitCode: Int32?`
13. `terminationSignal: Int32?`
14. `completionReason: TerminalCompletionReason?`
15. `lastOutputAt: Date?`
16. `outputLineCount: Int`
17. `transcriptPath: String?`
18. `promptSnapshot: TerminalPromptSnapshot?`

### 6.2 TerminalExecutionOutcome

所有任务结束后都必须产出统一结果：

1. `taskId: String`
2. `exitCode: Int32?`
3. `terminationSignal: Int32?`
4. `completionReason: TerminalCompletionReason`
5. `startedAt: Date?`
6. `endedAt: Date?`
7. `transcriptPath: String?`
8. `finalOutputSnippet: String`

### 6.3 TerminalCompletionReason

建议枚举：

1. `exitedZero`
2. `exitedNonZero`
3. `terminatedBySignal`
4. `timedOut`
5. `cancelledByAgent`
6. `cancelledByUser`
7. `runtimeFailure`

### 6.4 TerminalTaskStatus

建议状态收敛为：

1. `launching`
2. `running`
3. `waitingForInput`
4. `completed`
5. `failed`
6. `interrupted`
7. `timedOut`
8. `terminated`

不再保留旧的 `runningForeground` / `runningBackground` / `waitingForPrompt` 这类以旧 transport 为中心的状态命名。

## 7. 新工具协议

本次需求调整后，bash tool 输入协议应直接收口，不保留历史兼容字段。

### 7.1 创建类请求

字段：

1. `operation`: `start`
2. `task_id`
3. `command`
4. `execution_mode`
5. `working_directory`
6. `environment_overrides`
7. `timeout`
8. `wait_policy`

建议 `execution_mode` 仅保留：

1. `attached`
2. `detached`

建议 `wait_policy` 仅保留：

1. `until_exit`
2. `until_quiet`
3. `no_wait`

### 7.2 控制类请求

字段：

1. `operation`
2. `task_id`
3. `input`
4. `tail_lines`
5. `force`

`operation` 建议枚举：

1. `send_input`
2. `interrupt`
3. `terminate`
4. `status`
5. `read_output`
6. `cleanup`

如无充分场景，不单独保留 `restart`。PTY 模型下任务是一次性对象，结束后应新建任务，而不是重启旧会话。

### 7.3 请求约束

1. `start` 必须带 `task_id` 和 `command`。
2. 所有控制类请求必须带 `task_id`。
3. `send_input` 必须带 `input`。
4. 已完成任务不能再接受输入。
5. `cleanup` 只能对已结束任务生效。

## 8. 前台与后台统一策略

旧方案把前台与后台视为两条实现路径。PTY 方案下不再这样划分。

统一策略如下：

1. `attached` 任务创建 PTY 后立即把输出接到当前工具调用，并按 `wait_policy` 决定何时返回。
2. `detached` 任务创建 PTY 后继续运行，但 transcript 仍持续采集并可通过 `read_output` 读取。
3. 无论 attached 还是 detached，底层都是真实 PTY，会话能力一致。
4. 所有任务都有 PID、进程组、transcript 和完成态。

因此新架构不再需要“后台任务专属 launcher 协议 + meta 文件”这种补丁式设计。

## 9. Prompt 与交互识别

PTY 方案并不等于必须自动处理所有 prompt，但它至少提供正确的观察基础。

本期需求建议按以下原则实现：

1. Runtime 负责提供稳定的输出流、静默窗口、任务存活状态和最近输入上下文。
2. Prompt 分类器负责把当前输出归纳为 `yesNo`、`pressEnter`、`secret`、`destructiveConfirmation`、`textInput`、`unknown` 等类型。
3. 自动回复策略由上层 agent 决定，Runtime 只执行明确的 `send_input`。
4. 涉及敏感输入或破坏性确认时，应升级为用户决策，而不是自动写入 PTY。

也就是说，PTY 解决的是“交互通道正确性”，不是“所有 prompt 自动化”本身。

## 10. 对现有代码的删除要求

需求已明确不考虑兼容，因此以下历史实现可以直接删除或替换：

1. `BashSession` 中基于 `Process + Pipe + sentinel` 的前台执行模型。
2. 围绕 sentinel 的完成态解析与 timeout 文本拼接逻辑。
3. `background` / `interactive` / `interrupt` 兼容字段归一化。
4. 依赖“当前活动命令”的隐式控制语义。
5. 后台任务用 `command & echo $!` 启动并依赖 log/meta 文件补完成态的旧设计。

允许保留但应重写语义的对象：

1. `BashTaskRegistry`
2. `ToolCall` 中终端任务相关持久化字段
3. 终端任务 UI 展示层

## 11. 迁移要求

虽然不做兼容，但实现顺序仍应受控，避免 UI 和持久化层在过渡期崩坏。

建议按以下顺序落地：

1. 先新增 PTY Runtime 和新请求协议。
2. 再让 `ClaudeService+BashTool` 完全切到新路由。
3. 接着重写 `ToolExecutionResult` 的 terminal 映射。
4. 然后重写 `BashTaskRegistry` / `TerminalTaskSnapshot` / transcript 持久化。
5. 最后删除旧 `BashSession` 和所有兼容分支。

这里的“最后删除”是指代码切换顺序，不是指产品行为保留。合并时应只保留新语义，不保留运行时开关。

## 12. 测试要求

旧测试不应被当作兼容目标，新测试应围绕 PTY 事实语义重建。

### 12.1 单元测试

必须新增或重写以下测试族：

1. `PtyProcessControllerTests`
2. `TerminalTaskRuntimeTests`
3. `BashToolOperationRouterTests`
4. `TerminalTranscriptStoreTests`
5. `ToolExecutionResultTerminalTests`

覆盖重点：

1. 创建 PTY 任务后可读到实时输出。
2. `send_input(task_id)` 只作用于目标任务。
3. `interrupt(task_id)` 向正确进程组发送 `SIGINT`。
4. `terminate(task_id)` 后任务进入终态。
5. 非零退出码映射为 failure。
6. 超时映射为 `timedOut`。
7. detached 任务可被查询、读取输出和清理。

### 12.2 集成测试

至少覆盖以下场景：

1. `python` 或 `node` REPL 可以真正接收多轮输入。
2. `bash -lc 'read name; echo hello $name'` 可以完成问答闭环。
3. `python -m http.server` 作为 detached 任务可稳定读取输出并终止。
4. `false`、`exit 2`、被 `SIGTERM` 结束三类退出都能正确映射。
5. 两个 detached 任务并存时，读输出和终止按 `task_id` 精确路由。

## 13. 风险与取舍

### 13.1 PTY 实现复杂度更高

这是事实，但复杂度属于“必要复杂度”。旧模型的简单只是把复杂度转移给了兼容逻辑和错误语义。

### 13.2 每任务独立 PTY 会改变旧的 shell 心智模型

这会让部分依赖持久 shell 上下文的旧流程失效，但它带来的任务隔离、可控性和调试性更重要。需要共享上下文时，应显式在同一任务里继续交互，而不是依赖隐藏全局 shell。

### 13.3 UI 和持久化层需要一起调整

因为状态命名、输出来源、任务生命周期都变了，所以不要试图让 UI 继续假装旧数据结构不变。应同步更新摘要文案、状态 badge 和详情页字段。

## 14. 最终建议

新的需求已经足够明确：不要再把时间花在旧 BashSession 的修补上。

正确的方向只有一个：

1. 直接引入 PTY Runtime。
2. 让每个任务拥有独立 PTY 和明确 `task_id`。
3. 删除旧 Pipe/Sentinel 运行时与兼容语义。
4. 以新的任务状态、输出存储和结果映射重建 bash tool。

这不是一次“加固”，而是一次运行时替换。文档、实现、测试和 UI 都应围绕这个前提推进。
