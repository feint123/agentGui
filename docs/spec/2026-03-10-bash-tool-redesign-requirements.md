# BashTool 重设计需求说明

日期：2026-03-10

关联对象：`BashSession`、`ClaudeService+BashTool`、`ClaudeService+ToolBuilder`、`ClaudeService+AgenticLoop`、`ToolCall`、终端输出展示 UI

设计基准：将 BashTool 从“持久 shell 命令执行器”升级为“受管终端会话运行时”，让 agent 能更稳定地判断命令类型、持续观察命令状态、处理交互式流程，并管理后台任务生命周期。

## 0. 当前已落地状态（2026-03-10）

本说明最初用于定义 BashTool 重设计目标。经过本轮实现后，以下能力已经落地，并应视为当前 shipped behavior。

### 0.1 已落地的输入 schema

当前 `bash` 工具已支持以下主字段：

- `command`
- `task_id`
- `execution_mode`: `auto | foreground | background | interactive`
- `input`
- `signal`: `interrupt | terminate`
- `goal_hint`
- `scan_policy`: `adaptive | manual`
- `auto_reply_policy`: `safeOnly | disabled`
- `timeout`
- `restart`

兼容字段仍保留，并会在运行时统一归一化到受管任务模型：

- `background`
- `interactive`
- `interrupt`

### 0.2 已落地的任务状态与持久化元数据

当前已统一使用以下任务状态：

- `queued`
- `classifying`
- `launching`
- `runningForeground`
- `waitingForPrompt`
- `runningBackground`
- `completed`
- `failed`
- `interrupted`
- `timedOut`
- `needsUserDecision`

任务状态会同步写入 `ToolCall` 元数据，当前已持久化的字段包括：

- `terminalTaskId`
- `terminalTaskStatus`
- `terminalPromptSummary`
- `terminalAgentActionsJSON`
- `terminalExecutionMode`

### 0.3 当前实际支持的 prompt 类别

数据模型已为更多 prompt 类型预留枚举，但本轮真正接入自动识别与处理的类别只有以下几类：

- `yesNo`
- `pressEnter`
- `secret`
- `destructiveConfirmation`

当前行为边界如下：

- yes/no 提示可由 agent 按安全默认值自动回复
- `Press Enter to continue` 可自动继续
- 密码、token 等敏感输入不会自动回复，只会升级为用户决策
- 覆盖、删除等破坏性确认不会自动确认，只会升级为用户决策

`singleChoice`、`multiChoice`、`textInput`、`pathInput`、`unknown` 仍属于模型预留方向，本轮未完成通用自动处理闭环。

### 0.4 当前 transport 与交互限制

当前实现仍基于 `BashSession` 的 `Process + Pipe + sentinel` 模型，而非 PTY。当前应明确接受以下限制：

- 不保证 `vim`、`nano`、`less`、`top`、`fzf` 等强终端依赖程序可稳定工作
- 交互识别仍主要基于输出内容与静默窗口，不是操作系统级 prompt 事件
- ask-user 升级当前只支持结构化选项，不支持把敏感自由文本安全回填到终端
- 一次只管理单个前台命令；后台任务通过受管任务状态做持续观察

### 0.5 当前 UI 落地范围

当前 UI 已完成以下展示：

- 工具行摘要优先展示受管终端任务状态，而不是原始输出首行
- 工具详情页展示命令、任务状态、prompt 摘要、agent 动作和输出片段
- bash 工具气泡头部展示执行模式、任务状态、最近一次 agent 自动动作 badge

以下能力仍未落地：

- 完整终端面板式 transcript 浏览
- 真正的后台任务控制中心
- 基于 PTY 的高保真交互回放

## 1. 背景

当前项目已经具备一版可用的 BashTool：

- 基于持久 `zsh` 会话执行命令
- 支持 `background: true` 将任务放到后台
- 支持 `interactive: true`、`input`、`interrupt` 进行简单交互
- Agentic Loop 会轮询输出并把终端内容同步到 UI

这套能力已经足以覆盖基础的读文件、运行脚本、执行构建命令等场景，但它仍然偏“命令调用器”，还不是“可协作的终端代理”。

当前最明显的缺口有三类：

- 命令模式判断仍然依赖人工或少量正则，agent 需要自己猜哪些命令应后台运行、哪些命令会进入交互
- 交互支持仍然停留在“检测到静默后返回，让 agent 再发一段 input”，缺少 prompt 级别的理解和动作闭环
- 后台任务与前台任务的状态模型不统一，缺少定时扫描、任务登记、重连、停止、输出订阅等完整能力

用户希望的新 BashTool 不是简单增加几个参数，而是让 agent 能更灵活地和 shell 对话：自动分析执行方式、持续观察命令行为、在交互式流程中自己继续操作，并在必要时才升级为需要用户介入。

## 2. 基于当前实现的结论

### 2.1 当前 Bash 会话模型

当前 `BashSession` 使用单一 `Process` + `Pipe` 持有一个持久 `zsh` 进程，并通过 sentinel 字符串判断前台命令是否结束。

这带来的优点是实现简单、上下文可持续、容易做串行工具调用；但也存在天然限制：

- 更接近管道式命令执行，不是真正的 PTY 终端
- 许多 TUI / REPL / 全屏交互程序兼容性有限
- 交互识别依赖输出静默窗口，不是基于 prompt 事件
- 一个前台命令运行时，新的前台命令无法开始

### 2.2 当前自动识别能力偏弱

当前只对少量命令做规则式交互判断，例如：

- `git add -p`
- `git rebase -i`
- 无 `-m` 的 `git commit`
- `npm init` / `npx create`
- 裸 `python` / `node` / `irb` 等 REPL

这能覆盖少量典型例子，但仍无法稳定处理以下情况：

- 先输出几行日志后再询问输入的安装器
- 运行后不退出，但也不是标准服务进程的 watcher
- 需要 agent 连续多轮选择或确认的脚手架命令
- 先进入前台运行，随后又分叉成后台常驻任务的命令

### 2.3 当前后台任务能力仍是“放出去就算完成”

目前后台命令主要返回 PID 和日志路径。这个模型对“启动 dev server”有效，但对 agent 来说仍不够：

- 没有统一的后台任务注册表
- 没有任务状态判断标准
- 没有成功启动、启动失败、端口占用、退出重启等结构化事件
- agent 需要自己记住 log 路径并再次读取

### 2.4 当前交互闭环不完整

虽然已有 `input` 和 `interrupt`，但 agent 与交互命令的关系仍不够自然：

- 缺少“当前 prompt 是什么”的结构化描述
- 缺少 prompt 类型识别，例如 yes/no、编号选择、文本输入、密码、编辑器接管
- 缺少 agent 自动答复策略
- 缺少“何时必须 ask_user_question、何时允许 agent 自主继续”的边界

## 3. 问题定义

### 3.1 核心问题

当前 BashTool 以“执行一条命令”为中心，而不是以“管理一段终端任务”为中心。

这会导致 agent 在复杂 shell 场景下缺少稳定的行为模型：

- 不知道该前台执行还是后台执行
- 不知道命令是在正常运行、等待输入，还是已经卡死
- 不知道自己应该继续回答 prompt，还是应该询问用户
- 不知道如何持续跟踪后台任务，而不是把后台任务当成一次性输出

### 3.2 直接影响

- agent 使用 BashTool 时会更保守，很多本可自动处理的流程会中断
- 一些安装器、脚手架、向导式命令会在中途悬空
- 用户难以信任 agent 对 shell 任务的掌控能力
- UI 中的工具调用记录缺少“任务级”语义，更多只是输出片段

## 4. 方案对比

### 方案 A：继续扩充命令正则和参数

做法：继续在现有 `background`、`interactive` 模型上增加规则与提示。

优点：

- 改动小
- 易于兼容现有实现

缺点：

- 仍然以“单次调用”思维为主
- 交互与后台任务都只是补丁式增强
- 难以覆盖真实终端中的动态行为

### 方案 B：引入命令分类器，但仍保留当前会话模型

做法：在命令执行前增加自动分类层，判断命令更适合 foreground / background / interactive；执行后通过轮询输出补状态。

优点：

- 能显著减少 agent 猜测成本
- 比方案 A 更实用

缺点：

- 仍缺少统一任务状态机
- 交互阶段依旧比较脆弱
- 后台任务治理仍然不完整

### 方案 C：受管终端会话运行时

做法：将 BashTool 重构为“命令分类器 + 会话状态机 + 定时扫描器 + 交互控制器 + 后台任务注册表”的组合系统。agent 提交的是“终端动作请求”，运行时负责分类、执行、扫描、事件归纳和继续交互。

优点：

- 最符合用户希望的“agent 更灵活地和 bash 交流”
- 能统一前台、后台、交互式命令的生命周期
- 更利于 UI、日志、恢复、权限控制和后续扩展

缺点：

- 设计和实现复杂度明显提高
- 需要补足更多测试与状态建模

### 推荐方案

推荐采用方案 C。

原因：

- 用户诉求不是单点增强，而是 BashTool 的能力模型升级
- 当前项目已经有 agentic loop、工具时间线、状态展示基础，适合承接任务级终端模型
- 如果只做规则补丁，很快还会遇到新的边界问题

## 5. 目标

本次重设计需要达成以下目标：

- 让 agent 在大多数 shell 场景下不必手工决定 `background` 或 `interactive`
- 让 BashTool 能定时扫描命令输出和运行态，并将其归纳为结构化状态
- 让交互式命令支持 agent 自动继续操作，而不是只返回半截输出等待外部人工接管
- 让后台任务拥有统一的登记、观察、停止、重连和结果归档能力
- 让工具调用记录从“输出文本”升级为“可观察的终端任务”

目标效果：

- agent 对 bash 的使用更接近真实开发者使用终端，而不是频繁碰壁的命令执行器
- 常见脚手架、安装器、watcher、server、REPL、确认式命令都能有稳定路径
- 用户只在真正涉及风险确认、敏感信息、业务选择时才被打断

## 6. 范围

### 6.1 本期范围

本期需求必须覆盖：

- 命令类型自动分类
- 前台 / 后台 / 交互式统一状态机
- 定时扫描与事件归纳
- agent 自动处理交互 prompt
- 后台任务注册、观察、停止与输出订阅
- UI 中的任务级展示与状态反馈
- 安全边界与升级给用户的规则

### 6.2 非本期范围

本期不要求：

- 完整支持所有 curses / full-screen TUI 程序
- 自动代填系统密码或 macOS 权限弹窗
- 构建完整终端模拟器 UI
- 多会话共享同一个 shell 进程
- 远程 SSH 会话编排平台化

## 7. 总体设计原则

### 7.1 任务优先，不是单次命令优先

BashTool 应以“终端任务”为主抽象。一次调用不一定等于一次完成，可能经历：分类、启动、等待输出、等待 prompt、继续输入、转后台、结束等多个阶段。

### 7.2 自动优先，显式覆盖兜底

默认情况下由系统自动判断执行模式；仅在 agent 明确指定时，才覆盖自动判断。

### 7.3 结构化事件优先于原始文本

原始终端输出必须保留，但上层状态判断不能只靠拼接文本，而应形成结构化事件：

- `running`
- `waiting_for_input`
- `background_started`
- `completed`
- `failed`
- `timed_out`
- `needs_user_decision`

### 7.4 升级给用户必须克制

只有在下列场景才应主动打断用户：

- 涉及高风险 destructive 操作
- 需要敏感凭据或不可推断的信息
- 出现多选业务决策且 agent 无法安全默认

## 8. 功能需求

### 8.1 命令分类器

优先级：P0

要求：

- BashTool 在执行命令前必须先进行模式分类
- 分类结果至少包括：`foreground`、`background`、`interactive`、`interactive-background-bootstrap`、`monitor-only`、`unknown`
- 分类输入必须综合以下信息，而不是只看命令名：
  - 命令文本
  - 历史同类命令表现
  - 用户任务上下文
  - agent 当前目标，例如“启动服务并继续编码”或“进入向导完成初始化”
- agent 可以显式指定执行模式，但默认不要求它每次手工指定
- 当分类置信度不足时，系统应使用较保守策略并记录原因

说明：

- `interactive-background-bootstrap` 用于这类命令：先完成一小段交互，随后进入后台常驻运行，例如某些 dev server 初始化器

### 8.2 定时扫描器

优先级：P0

要求：

- 系统必须对活动终端任务进行定时扫描
- 扫描周期应可配置，默认建议 300ms 到 1000ms 之间
- 扫描器必须观察以下信息：
  - 新增输出
  - 输出是否持续流动或进入静默
  - 进程是否仍存活
  - 是否出现 prompt、菜单、确认、密码请求、编辑器接管等模式
  - 后台任务是否成功启动、异常退出或无输出卡死
- 扫描结果必须转成结构化事件，而不是只更新一段完整文本
- UI 层和 agent 层都应消费同一份扫描事件，而不是重复轮询原始输出

### 8.3 交互式命令自动接管

优先级：P0

要求：

- 对常见交互 prompt，agent 应能够自动继续操作
- 长期目标至少支持以下 prompt 类型识别：
  - yes / no 确认
  - 单选菜单
  - 多选菜单
  - 文本输入
  - 路径输入
  - 覆盖文件确认
  - 按回车继续
- 当前已完成的最小实现子集为：yes/no、按回车继续、敏感输入识别、破坏性确认识别。
- 每次自动回复都必须形成一条结构化“agent input event”，可在 UI 中查看
- 系统必须允许为不同 prompt 类型配置默认策略，例如：
  - 安全默认 yes/no 策略
  - 默认接受推荐选项
  - 默认保持现有文件并询问用户
- 对以下场景不得无条件自动回复：
  - 密码 / token / 私钥 / 二次验证
  - 破坏性确认，例如批量删除、重置、发布、覆盖生产配置
  - 无明确推荐项且选择结果不可逆的业务分叉

### 8.4 用户升级规则

优先级：P0

要求：

- 当交互流程进入 agent 不应自行决定的场景时，BashTool 必须产出 `needs_user_decision` 事件
- 系统必须能把该事件转换成用户可回答的问题，而不是只显示终端原文
- 问题内容至少应包含：
  - 当前命令
  - prompt 摘要
  - 可选项
  - 推荐项与理由
  - 超时策略
- 用户答复后，系统应把答复继续发送给原任务，而不是新建无关命令

### 8.5 后台任务注册表

优先级：P0

要求：

- 后台启动的命令必须登记为可追踪任务，而不是只返回 PID 和临时 log 路径
- 每个后台任务至少记录：
  - `job_id`
  - 原始命令
  - 工作目录
  - 启动时间
  - 最近状态
  - PID 或进程标识
  - 输出来源
  - 最近扫描时间
  - 停止方式
- agent 必须能通过统一接口完成：
  - 查看后台任务列表
  - 订阅某个任务输出
  - 停止某个任务
  - 重新附着查看状态
- 后台任务结束时，系统必须记录结束原因：正常退出、失败退出、被中断、超时清理、状态未知

### 8.6 前台与后台统一生命周期

优先级：P0

要求：

- 前台命令、交互命令、后台命令都必须映射到同一套任务生命周期模型
- 建议至少包含以下状态：
  - `queued`
  - `classifying`
  - `launching`
  - `running_foreground`
  - `waiting_for_prompt`
  - `running_background`
  - `completed`
  - `failed`
  - `interrupted`
  - `timed_out`
  - `needs_user_decision`
- 状态切换必须可记录、可回放、可显示

### 8.7 Tool Schema 重构

优先级：P1

要求：

- BashTool 输入模型应从单一 `command + flags` 升级为更清晰的动作模型
- 当前已实现并对外暴露以下字段：
  - `command`
  - `execution_mode`: `auto | foreground | background | interactive`
  - `task_id`: 对已有任务继续操作时使用
  - `input`: 向当前任务发送输入
  - `signal`: 如 `interrupt`、`terminate`
  - `scan_policy`: 当前实现为 `adaptive | manual`
  - `goal_hint`: 告诉分类器当前目标，例如“启动后继续其他任务”
  - `auto_reply_policy`: 当前实现为 `safeOnly | disabled`
- 本轮还额外支持：
  - `timeout`
  - `restart`
- 旧字段 `background`、`interactive`、`interrupt` 在兼容阶段可保留，但不应继续作为唯一主入口

### 8.8 输出模型重构

优先级：P1

要求：

- 工具返回值不能只是一段字符串
- 至少应有以下结构化信息：
  - `task_id`
  - `status`
  - `classification`
  - `summary`
  - `new_output`
  - `prompt_snapshot`
  - `agent_actions`
  - `next_suggested_action`
- 同时仍需保留原始输出文本，方便调试与回放
- 当前实现中，结构化状态主要通过 `ToolCall` 元数据和任务事件 JSON 暴露，尚未把所有字段组装为单独的统一返回 payload。

### 8.9 UI 展示要求

优先级：P1

要求：

- BashTool 在消息流中应展示为“终端任务行”，而不是单纯输出气泡
- 行摘要至少包含：
  - 当前状态
  - 执行模式
  - 命令摘要
  - 是否后台运行
  - 是否等待输入
  - 最近一次 agent 自动回复
- 展开态应展示：
  - 最新输出片段
  - prompt 摘要
  - agent 连续输入记录
  - 后台任务控制动作，如停止、查看输出、重新附着
- 如果任务由前台切换到后台，UI 必须清楚表达状态转换，而不是生成一条完全无关的新记录

### 8.10 失败与恢复

优先级：P1

要求：

- 当扫描器检测到卡死、无输出超时、进程退出但任务未归档、prompt 无法识别时，系统必须有明确恢复策略
- 至少支持以下恢复动作：
  - 继续等待
  - 自动发送安全默认输入
  - 中断任务
  - 转交用户决策
  - 将任务转后台观察
- 每次恢复动作必须记录原因和执行结果

### 8.11 安全策略

优先级：P0

要求：

- 自动回复能力必须受到安全策略约束
- 对高风险命令与确认流程，默认不得 silent auto-confirm
- 系统必须支持危险等级判断，至少包含：`low`、`medium`、`high`
- 高风险场景必须默认升级给用户或要求明确策略放行
- 日志中涉及敏感输入时，UI 默认应掩码显示

### 8.12 兼容与迁移

优先级：P2

要求：

- 现有基于 `background` / `interactive` 的调用在迁移期内应继续可用
- 旧调用结果在 UI 中不应被破坏
- 新旧逻辑应能通过设置或版本门控逐步切换
- 当前已完成的兼容路径：旧字段会在 `normalizeBashToolRequest` 中被归一化到新请求模型，再进入统一的分类、轮询与状态归约流程。

## 9. 建议的数据与状态模型

以下为需求阶段建议，不要求本文件内锁死实现细节。

### 9.1 终端任务实体

建议新增或抽象出 `TerminalTask`：

- `id`
- `sessionId`
- `command`
- `executionMode`
- `classification`
- `status`
- `workingDirectory`
- `pid`
- `startedAt`
- `endedAt`
- `lastScanAt`
- `latestOutputSnippet`
- `fullTranscriptRef`
- `currentPrompt`
- `autoReplyEnabled`
- `riskLevel`

### 9.2 终端事件实体

建议新增 `TerminalTaskEvent`：

- `taskId`
- `timestamp`
- `kind`
- `summary`
- `rawText`
- `structuredPayload`

事件种类建议包括：

- `output`
- `prompt_detected`
- `agent_input`
- `state_changed`
- `background_registered`
- `process_exit`
- `user_decision_requested`
- `signal_sent`

## 10. 验收标准

### 10.1 自动分类

- agent 执行 `npm run dev`、`swift build --watch`、`python -m http.server` 这类命令时，系统应默认倾向后台任务或可持续观察任务，而不是长时间阻塞前台
- agent 执行 `npx create-*`、`git add -p`、`git commit`、`read -p` 这类命令时，系统应自动进入交互模式或等待 prompt 模式

### 10.2 交互自动继续

- 对 yes/no、编号选择、回车继续等常见 prompt，agent 能至少连续完成 3 轮自动交互，无需用户介入
- 每轮自动输入都能在 UI 或日志中回放

### 10.3 用户升级

- 当命令请求密码、敏感令牌或高风险确认时，系统不会自动胡乱继续，而是明确向用户提问
- 用户回答后，原任务能继续执行而不是丢失上下文

### 10.4 后台任务治理

- agent 启动一个开发服务器后，后续可以通过任务 ID 查看状态、读取最新输出并主动停止
- 后台任务异常退出时，UI 能反映失败，而不是停留在“已启动”

### 10.5 恢复能力

- 当前台任务 10 秒无输出但进程仍存活时，系统不会立即误判完成，而会进入可解释的等待或恢复路径
- 未识别 prompt 出现时，系统会产生 `needs_user_decision` 或 `unrecognized_prompt` 事件，而不是无限挂起

## 11. 风险与开放问题

### 11.1 PTY 需求边界

如果后续需要更稳定支持 `fzf`、`top`、`vim`、`less`、`nano` 等强终端依赖程序，当前 `Pipe` 模型大概率不够，需评估升级到 PTY。

### 11.2 自动回复误判风险

prompt 自动识别和自动回复一定会有误判风险，因此必须从需求阶段就要求：

- 风险分级
- 默认策略可配置
- 自动回复可回放
- 高风险默认不上自动

### 11.3 任务数量与性能

引入定时扫描后，要控制同时活跃任务数量、扫描频率和输出缓存，避免 UI 与存储层被大量日志拖慢。

## 12. 推荐实施顺序

建议分三阶段推进：

### 阶段一：能力打底

- 建立统一任务状态机
- 引入后台任务注册表
- 抽象扫描事件模型

### 阶段二：自动化增强

- 接入命令分类器
- 接入 prompt 检测与 agent 自动回复策略
- 打通 ask_user_question 升级链路

### 阶段三：产品化收敛

- 优化消息流中的 BashTool 展示
- 增加任务过滤、重连、停止、诊断能力
- 逐步弱化旧字段心智，完成新 schema 迁移
