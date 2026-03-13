# 结构化 Agent 定义与三角色收敛需求说明

日期：2026-03-13

关联对象：`WorkflowRoleDefinition`、`ClaudeService+Subagent`、`ToolRegistry`、`ToolDefinitionBuildContext`、`ACPClientService.buildSystemPrompt(...)`、`ClaudeService+ToolCallRecord`、`WorkflowAgentRunner`、`run_subagent` 工具说明、Agent 相关测试与内置文档资源

## 1. 背景

当前项目的子代理能力已经具备基本运行闭环，但 Agent 定义方式仍然以代码硬编码为主。`WorkflowRoleDefinition` 直接承载角色名、描述、系统提示词、工具授权、工件契约和回合预算；与此同时，主 Agent 的系统提示、`run_subagent` 工具说明、测试用例和调用记录展示，又在多个位置重复引用这些角色名与角色职责。

目前已经确认的直接耦合点包括：

- `WorkflowRoleDefinition.all` 与 `WorkflowRoleDefinition.find(named:)` 作为内置 Agent 总表
- `ClaudeService+Subagent` 通过角色名查找定义并运行子代理 loop
- `ToolDefinitionBuildContext` 用 `WorkflowRoleDefinition.all` 生成 `run_subagent` 的可选 agent 列表与说明文本
- `ACPClientService.buildSystemPrompt(...)` 在系统提示中手写何时应调用哪些 subagent
- `ClaudeService+ToolCallRecord` 根据角色定义补充展示信息
- 多个测试文件直接断言 `planner`、`coder`、`reviewer`、`executor`、`creative_memory_manager`、`writer` 等角色存在

这类设计在项目早期可以快速推进，但已经出现三个结构性问题：

第一，Agent 定义与 Agent 文档没有分离。系统提示词和角色说明混在 Swift 源码里，导致产品语义、工程策略和运行时代码耦合过深。更新 Agent 文案需要改代码、重新编译、重新走回归，成本偏高。

第二，角色集合不断膨胀，但职责边界并不稳定。当前同一系统内同时存在 `planner`、`explorer`、`coder`、`reviewer`、`executor`、`verifier`、`creative_memory_manager`、`writer` 等角色，其中不少角色的职责边界彼此交叠，主 Agent 还在系统提示中继续手写“何时调用谁”。这会抬高调度复杂度，也会让模型更容易出现过度委托、角色选择不稳定和提示词互相竞争。

第三，成熟产品的常见做法已经更接近“声明式 Agent 文件 + 运行时加载”。本次调研得到的外部经验高度一致：

- VS Code 自定义 Agent 使用 `.agent.md` 或 Claude 风格 Markdown 文件，通过 frontmatter 声明名称、描述、工具、可见性和 handoff，而把行为规范写在 Markdown 正文中
- Anthropic 的 Agent / prompt 最佳实践强调：系统提示应清晰、角色应明确、工具权限应最小化、复杂上下文应结构化表达、避免过度提示导致过触发
- OpenAI 的 Agent 工程化方向强调：模型、工具、知识、流程控制和评估应模块化，而不是混杂在一段不可审计的代码常量里

因此，当前项目需要把 Agent 定义从“硬编码角色对象”升级为“结构化文件定义 + 运行时解析 + 严格校验 + 三角色收敛”的方案。

## 2. 目标

本需求的目标如下：

- 用结构化文件承载内置 Agent 定义，不再把 Agent 的主要文案、角色说明和系统提示长期硬编码在 Swift 源码中
- 将当前 Agent 目录收敛为仅保留三个内置角色：`explore`、`worker`、`verifier`
- 建立一套稳定的 Agent 文档 schema，使 Agent 名称、描述、工具授权、回合预算、输出契约与行为规范可独立维护、可审计、可测试
- 建立 Agent 加载与校验机制，让运行时只消费通过校验的结构化定义，并在错误时给出明确诊断
- 让 `run_subagent`、主系统提示、工具说明、测试和展示层统一从同一份 Agent 注册表读取角色信息，消除重复名单和重复文案
- 让新的三角色体系职责清晰、最小充分、可与现有 main agent 编排方式兼容

## 3. 不在本次范围

- 不要求本期把 workflow runtime 整体替换成文件化 workflow 定义
- 不要求本期开放用户自定义 Agent 编辑 UI
- 不要求本期支持远程下载、热更新或在线安装 Agent 包
- 不要求本期把所有 prompt 文件、skills 或 instructions 统一并入同一格式
- 不要求本期保留 `planner`、`coder`、`reviewer`、`executor`、`creative_memory_manager`、`writer` 的兼容运行能力
- 不要求本期设计多语言本地化系统，Agent 文档先以单一权威文本为准

## 4. 现状问题定义

### 4.1 Agent 定义与运行时代码强耦合

当前 `WorkflowRoleDefinition` 同时承担以下职责：

- 角色目录
- 系统提示文本容器
- 工具授权容器
- workflow 工件契约容器
- `run_subagent` 查找入口

这意味着任何角色文案变更都需要进入编译代码路径，而不是作为产品配置或资源文档单独演进。

### 4.2 Agent 名单在多个入口重复出现

Agent 名称不仅存在于 `WorkflowRoleDefinition.all`，还存在于：

- 主 Agent 系统提示中的“何时调用哪个 subagent”说明
- `run_subagent` 工具描述和参数枚举
- 调用记录展示与若干测试断言

如果只改一个入口，系统会进入“定义已替换，但文案和验证仍引用旧角色”的半重构状态。

### 4.3 角色过多，职责边界不稳定

当前目录中至少存在探索、规划、编码、审查、执行、验证、创作记忆、写作等多个子角色。对当前产品而言，这已经超过了一个稳定内置 Agent 体系应有的复杂度。成熟工程经验通常更偏向于：

- 用少量高辨识度角色承载高频工作流
- 每个角色权限最小化
- 用主 Agent 或 workflow 编排补足细分流程，而不是把流程切成过多子人格

继续维持当前目录，会带来：

- 主 Agent 调度策略持续膨胀
- 提示词和角色说明发生语义重叠
- 用户和模型都难以形成稳定心智模型

### 4.4 当前角色定义不适合作为可复用文档资产

示例 Agent 文件已经证明，成熟格式通常包含两部分：

- frontmatter：机器可解析的结构化元数据
- Markdown 正文：面向模型的高质量行为说明

当前项目只有结构体，没有独立文档资产，无法进行独立审阅、文案优化、A/B 对比、schema 校验与未来复用。

## 5. 总体方案

### 5.1 核心原则

- 单一真源：所有内置 Agent 的名称、描述、工具授权、可见性、系统提示和预算都必须来自结构化文件
- 结构与正文分离：可解析元数据放在 frontmatter，行为说明放在 Markdown 正文，不再混写在 Swift 常量中
- 三角色收敛：内置 Agent 仅保留 `explore`、`worker`、`verifier`
- 最小权限：每个角色只暴露完成其职责所必需的工具和能力
- 明确边界：角色负责做什么、不能做什么、输出什么，必须写进文档并可被校验
- 可诊断：加载失败、字段缺失、未知工具组、非法角色名、正文为空等情况都必须可见

### 5.2 目标形态

系统需要形成以下结构：

1. `AgentDefinitionDocument`
表示从 Markdown 文件解析出的原始文档对象，包含 frontmatter 元数据与正文。

2. `AgentDefinitionLoader`
负责扫描内置 Agent 资源目录、解析文件、校验 schema，并生成中间模型。

3. `AgentCatalog`
作为运行时唯一 Agent 注册表，提供 `all`、`find(named:)`、`userInvocableAgents`、`subagentInvocableAgents` 等查询能力。

4. `AgentRuntimeDefinition`
表示运行时使用的强类型对象，包含名称、描述、系统提示、工具授权、预算和运行约束。`run_subagent`、主系统提示、工具上下文和展示层都只依赖这一层。

在该模型下：

- Swift 代码不再手写三类 Agent 的大段系统提示
- `run_subagent` 只从 `AgentCatalog` 获取可用角色
- 主 Agent 系统提示中关于 subagent 的说明由 `AgentCatalog` 生成，不再写死旧名单
- 测试不再断言旧角色存在，而是断言目录只包含 `explore`、`worker`、`verifier`

## 6. 文件格式需求

### 功能点 1：采用 Markdown + frontmatter 作为 Agent 定义格式

系统必须使用结构化 Markdown 文件定义内置 Agent。每个文件由两部分组成：

- YAML frontmatter：机器可解析元数据
- Markdown 正文：系统提示主文本

文件必须可被源码包或 App Bundle 稳定加载，不能依赖运行时网络获取。

### 功能点 2：定义 Agent frontmatter 的最低字段集合

每个 Agent 文件至少必须包含以下字段：

- `name`：唯一标识，必须为小写 kebab 或 snake 风格中的一种，且本期固定只允许 `explore`、`worker`、`verifier`
- `display-name`：展示名称，用于 UI 与日志
- `description`：一句话描述该 Agent 的职责与适用场景
- `argument-hint`：调用该 Agent 时传给主 Agent 或用户的提示语
- `tools`：允许使用的工具或工具组列表
- `max-turns`：单次激活的最大回合数
- `user-invocable`：是否允许作为用户直接可选角色
- `subagent-invocable`：是否允许通过 `run_subagent` 被主 Agent 调用
- `output-contract`：该 Agent 默认输出契约标识，例如 `exploration_report`、`work_result`、`verification_report`

本期可选字段包括：

- `model-preference`
- `tags`
- `examples`
- `notes`

本期不允许在 frontmatter 中出现不受支持的自由字段而静默通过。未知字段必须被记录为校验错误或显式警告。

### 功能点 3：正文必须作为权威系统提示来源

Markdown 正文必须是该 Agent 的权威行为文档。运行时构造系统提示时，必须以正文为主，不允许再在 Swift 中长期维护另一份同职责的大段提示文本。

正文建议按固定结构组织，至少包括：

- 角色定位
- 适用场景
- 工作原则
- 明确禁止事项
- 输出要求

正文应优先采用清晰、直接、少歧义的表达方式，避免堆砌口号式或重复式提示。需要遵循已调研出的成熟经验：角色清晰、输出清晰、工具使用条件清晰、不要过度提示导致工具过触发。

### 功能点 4：文件目录必须稳定且可被 Xcode 资源化

本期内置 Agent 文件必须放入稳定目录，例如：

- `agentGui/Resources/Agents/explore.agent.md`
- `agentGui/Resources/Agents/worker.agent.md`
- `agentGui/Resources/Agents/verifier.agent.md`

要求：

- 目录必须加入 Xcode bundle 资源
- 加载器必须能从 App Bundle 读取
- 单元测试必须能在测试 bundle 或测试辅助路径中读取同一格式样本

## 7. Agent 加载与校验需求

### 功能点 5：建立统一 Agent 加载器

系统必须提供统一加载器，例如 `AgentDefinitionLoader`，至少负责：

- 扫描内置 Agent 文件目录
- 解析 Markdown frontmatter
- 提取正文
- 校验字段完整性与字段值合法性
- 产出运行时 Agent 对象

系统不得继续使用 `WorkflowRoleDefinition.all` 这类手写静态数组作为最终 Agent 目录真源。

### 功能点 6：建立统一 Agent 注册中心

系统必须建立唯一 Agent 注册中心，例如 `AgentCatalog`。该注册中心必须提供：

- `all`
- `find(named:)`
- `subagentInvocableAgents`
- `agentListText`
- `agentNameListText`

`run_subagent`、系统提示、工具说明、展示层和测试都必须通过该注册中心读取 Agent 信息，而不是直接引用某个角色结构体静态数组。

### 功能点 7：校验必须失败得明确

加载器至少需要校验以下错误：

- 缺少必填字段
- `name` 不在允许集合中
- 存在重复 name
- 正文为空或仅空白
- `tools` 引用了未知工具或未知工具组
- `max-turns` 非正整数
- `user-invocable` 与 `subagent-invocable` 组合非法
- `output-contract` 非法

错误处理要求：

- Debug / Test 环境下，校验失败必须直接暴露为可见错误
- Release 环境下，不允许静默降级为随机可运行状态
- 如果内置 Agent 加载失败导致目录不完整，系统必须拒绝进入“自称支持 subagent 但目录不完整”的状态

### 功能点 8：运行时模型与文档模型分层

文档解析对象与运行时执行对象必须分层：

- 文档层负责保留原始字段和正文
- 运行时层负责生成工具授权、执行预算、可见性和对外说明文本

这样做的目的是避免 UI、工具层或执行层直接依赖 YAML 解析细节。

## 8. 三角色收敛需求

### 功能点 9：内置角色固定为 explore / worker / verifier

本期内置 Agent 必须只保留三个：

- `explore`
- `worker`
- `verifier`

以下旧角色必须从内置目录中移除，并从主系统提示、工具说明、测试和展示文案中同步删除：

- `planner`
- `explorer`
- `coder`
- `reviewer`
- `executor`
- `creative_memory_manager`
- `writer`

说明：

- `explore` 是新的标准研究/探索角色，取代当前 `explorer`
- `worker` 吸收当前 `coder` 与一部分 `executor` 的执行能力，但不吸收独立 reviewer 的人格化职责
- `verifier` 保留为独立验证角色，作为质量闸门而不是泛化 reviewer

### 功能点 10：定义 explore 的职责边界

`explore` 的职责必须限定为：

- 搜索代码库、文档和批准的网页来源
- 汇总相关文件、关键符号、现状事实和风险点
- 为主 Agent 或 `worker` / `verifier` 提供结构化上下文

`explore` 的禁止事项必须至少包括：

- 不修改文件
- 不执行 shell 命令
- 不伪造未阅读过的事实
- 不直接给出“已完成实现”的结论

推荐工具集：只读编辑工具组 + 搜索能力 + Web 工具组。

推荐输出契约：结构化 exploration report。

### 功能点 11：定义 worker 的职责边界

`worker` 的职责必须限定为：

- 在已有目标与上下文基础上实施变更
- 读取必要文件
- 编辑文件
- 在需要时运行构建、测试或验证命令
- 产出简洁且可核对的变更总结

`worker` 的禁止事项必须至少包括：

- 不做与任务无关的扩展设计
- 不把“代码审查人格”和“最终验证结论”混入自身角色中
- 不在无必要时主动拆分出更多角色
- 不对未观察到的测试结果做结论性陈述

推荐工具集：读写编辑工具组 + shell 工具组 + 必要的只读上下文工具。

推荐输出契约：work result，包括 changed files、summary、verification evidence。

### 功能点 12：定义 verifier 的职责边界

`verifier` 的职责必须限定为：

- 审阅 `worker` 的执行结果和证据
- 判断需求是否满足、风险是否关闭、验证是否充分
- 在必要时要求补充证据或回退到下一轮修复

`verifier` 的禁止事项必须至少包括：

- 默认不编辑代码
- 默认不承担主实现职责
- 不用空泛语言替代验证结论
- 不把“看起来没问题”当作验证通过

推荐工具集：只读编辑工具组 + 搜索工具组。Shell 工具应默认关闭；如确需开放，只能作为严格受限选项，不得成为默认高权限角色。

推荐输出契约：verification report，包括 status、verified claims、unverified claims、blocking issues、next action。

## 9. Agent 文档打磨要求

### 功能点 13：三份 Agent 文档必须达到可直接投入运行的质量

三份 Agent 文档不是简单的字段搬运，必须按成熟工程经验进行重写和打磨。至少满足以下要求：

- 角色定位一句话即可辨识，不与其他角色重叠
- “何时使用”与“何时不要使用”必须同时写明
- 工具权限与角色职责一致，不出现能力过宽
- 输出格式或输出结构必须明确，避免自由散文式结束
- 文案应短而强，不写多余激进措辞，不堆砌 MUST / CRITICAL 等过度触发语

### 功能点 14：正文结构必须可复用

建议每个 Agent 正文统一采用类似结构：

- `# Role`
- `## Use When`
- `## Do Not Use When`
- `## Working Style`
- `## Tool Discipline`
- `## Output`

这不是 UI 呈现要求，而是为了让三份 Agent 文档有一致骨架，便于评审、对比和后续演进。

### 功能点 15：保留少量高价值示例，不堆砌长篇范例

结合 Anthropic 的 prompt 最佳实践，少量高质量示例比长篇泛泛描述更有效。本期允许为 `explore` 与 `verifier` 添加 1 至 3 个微型示例，帮助约束输出格式；但不得把正文写成冗长的示例大全。

## 10. 运行时接线改造需求

### 功能点 16：`run_subagent` 必须基于 AgentCatalog 工作

`ClaudeService+Subagent` 及相关运行入口必须改为：

- 从 `AgentCatalog.find(named:)` 查找角色
- 在错误提示中输出 `AgentCatalog` 的实际可用列表
- 使用运行时 Agent 定义构建子代理 loop 所需配置

不得继续直接从 `WorkflowRoleDefinition.all` 或等价硬编码数组取值。

### 功能点 17：`run_subagent` 工具说明必须动态来自 AgentCatalog

`ToolDefinitionBuildContext` 中与 Agent 列表相关的文本生成必须改为基于 `AgentCatalog`。要求：

- `agentListText` 只列出 `explore`、`worker`、`verifier`
- `agentNameListText` 只枚举当前可调用角色
- 工具描述中的使用建议与角色能力同步更新为三角色版本

### 功能点 18：主系统提示中的 subagent 规则必须重写

`ACPClientService.buildSystemPrompt(...)` 当前仍手写旧角色路由规则。本期必须改造为：

- 主系统提示只解释三角色体系
- 不再出现 `planner`、`coder`、`reviewer`、`executor`、`creative_memory_manager`、`writer`
- 研究任务优先委托 `explore`
- 实施任务优先委托 `worker`
- 最终验证由 `verifier` 承担

如果系统提示仍保留旧角色名，则视为需求未完成。

### 功能点 19：展示层与审计层必须使用新角色名

以下路径必须同步收敛到新角色名：

- `ToolCall` 记录中的 subagent agent name 展示
- 时间线 / 消息流中显示的角色名称
- 任何使用角色名做分类或图标映射的 UI 逻辑

目标不是新增 UI 功能，而是避免旧角色名残留在可见路径中。

## 11. 迁移与兼容策略

### 功能点 20：允许内部类型保留，但不允许继续作为真源

本期允许保留一个运行时强类型，例如继续存在 `WorkflowRoleDefinition` 或引入新的 `AgentRuntimeDefinition`。但该类型只能是“解析产物”，不能再是“Agent 内容真源”。

### 功能点 21：旧角色应直接删除，不做长期兼容壳

由于项目仍处于快速迭代阶段，本期不建议为旧角色名保留长期兼容层。原因如下：

- 旧角色职责本身已不再是目标产品语义
- 保留兼容会让主提示、测试和日志继续背负双重目录
- 三角色收敛的目标会被稀释

如需临时兼容，仅允许在非常薄的一层做短期错误提示映射，例如当收到旧角色名时，明确返回“该角色已移除，请改用 explore / worker / verifier”，而不是偷偷转发。

## 12. 测试与验收需求

### 功能点 22：为 Agent 加载器建立单元测试

至少覆盖以下场景：

- 成功加载三份合法 Agent 文件
- 缺少 frontmatter 必填字段时报错
- 重复 `name` 报错
- 未知工具组报错
- 正文为空报错
- 最终目录只包含 `explore`、`worker`、`verifier`

### 功能点 23：为运行时接线建立回归测试

至少覆盖以下场景：

- `run_subagent(agent_name: "explore")` 可正常查找到定义
- `run_subagent(agent_name: "worker")` 可正常构建工具集
- `run_subagent(agent_name: "verifier")` 可被主 Agent 调用
- 旧角色名调用会返回明确错误
- `run_subagent` 工具 schema 中的 agent 列表与 `AgentCatalog` 一致

### 功能点 24：为系统提示与工具说明建立文本级回归测试

至少覆盖以下场景：

- 主系统提示包含 `explore`、`worker`、`verifier`
- 主系统提示不再包含旧角色名
- `run_subagent` 的说明文本不再引用 `coder`、`reviewer` 等旧角色

### 功能点 25：建立资源完整性检查

测试必须验证三份 Agent 文件已进入 bundle 或测试资源路径。避免“代码路径已切换到文件加载，但打包时漏掉资源”的问题。

## 13. 非功能要求

### 13.1 可维护性

新增或修改 Agent 文案时，应主要改 Markdown 文件而不是 Swift 源码。变更应能被代码评审直接审阅为“结构字段变化 + 文案变化”，而不是埋在大段字符串常量中。

### 13.2 可观测性

系统至少需要在 debug 日志或诊断输出中说明：

- 加载了哪些 Agent 文件
- 每个 Agent 解析结果如何
- 是否存在校验警告或失败

### 13.3 安全性

Agent 工具权限必须遵循最小权限原则。特别是：

- `explore` 不得拿到写文件与 shell 权限
- `verifier` 默认不得拿到写文件权限
- `worker` 的 shell 权限必须受现有设置与工具授权共同约束

### 13.4 性能

Agent 文件加载应在应用启动或第一次需要 Agent 目录时完成，并可缓存。正常情况下不应在每次 `run_subagent` 调用时重新解析全部文件。

## 14. 实施建议

推荐按以下顺序实施：

1. 建立 `AgentDefinitionDocument`、frontmatter parser、校验器与 `AgentCatalog`
2. 新建三份内置 Agent 文档并补齐测试样本
3. 将 `run_subagent`、`ToolDefinitionBuildContext`、主系统提示改为依赖 `AgentCatalog`
4. 删除旧角色与旧文案引用
5. 补齐回归测试与 bundle 资源校验

## 15. 验收标准

满足以下条件时，视为本需求完成：

- 运行时内置 Agent 真源已切换为结构化文件，不再以硬编码角色数组作为内容真源
- 内置 Agent 目录只剩 `explore`、`worker`、`verifier`
- `run_subagent`、主系统提示、工具说明、展示层和测试均已同步到三角色体系
- 三份 Agent 文档均具备可直接运行的高质量正文，而非占位文本
- 关键加载、校验、接线与资源测试全部通过

## 16. 参考依据

本需求的设计依据来自以下已核对的工程实践方向：

- VS Code Custom Agents：采用 Markdown 文件 + YAML frontmatter 承载 Agent 名称、描述、工具与可见性，说明声明式 Agent 文件已是成熟形态
- Anthropic Prompting Best Practices：强调角色清晰、输出清晰、结构化上下文、最小权限工具和避免过度提示，这直接指导三份 Agent 文档的写法
- OpenAI Agents 工程化实践：强调模型、工具、知识、流程控制与评估分层组合，支持将 Agent 定义从业务代码中抽离出来形成独立配置资产

这些经验的共同结论是：Agent 越进入工程化阶段，就越不应把角色定义散落在运行时代码常量里，而应使用可解析、可校验、可审查的声明式资产来驱动。