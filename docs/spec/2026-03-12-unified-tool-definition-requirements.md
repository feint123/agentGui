# 统一工具定义源需求说明

日期：2026-03-12

关联对象：`ClaudeService+ToolBuilder`、`ClaudeService+Subagent`、`WorkflowAgentRunner`、`WorkflowRoleDefinition`、`WorkflowDefinition`、`ClaudeService+ToolDispatch`、`ToolCall`、设置页工具配置、未来 MCP / 插件接入层

## 1. 背景

当前项目已经同时具备主 Agent、`run_subagent` 子代理、`start_workflow` 多代理编排三条执行路径，但工具定义仍然分散在多个层级中维护。

已确认的重复入口包括：

- `ClaudeService+ToolBuilder.buildTools(...)`：主 Agent 工具清单、工具描述、输入 schema、workflow 列表入口
- `ClaudeService+Subagent.buildSubagentTools(...)`：子代理工具清单、工具描述、输入 schema
- `WorkflowAgentRunner.WorkflowToolStub.buildTools()`：workflow 运行时工具清单、工具描述、输入 schema
- `WorkflowRoleDefinition`：角色层通过 `enableTextEditor`、`enableBash`、`enableWebSearch` 等布尔字段声明能力，但并不直接持有标准化工具定义

这意味着同一个工具在不同执行路径下，往往要重复维护名称、描述、schema、可见性和能力开关。一旦工具字段、交互方式或安全策略发生变化，就容易出现以下问题：

- 主 Agent 和子代理暴露的 schema 不一致
- workflow 运行时使用的是另一套精简定义，语义逐渐偏离主入口
- 工具可用性判断散落在角色布尔开关、设置开关和构建函数中，缺少单一真源
- 新增工具时必须修改多个文件，回归成本高，容易漏改

项目在 2026-03-10 已经提出“统一工具注册表”的方向，但当前问题已经不仅是“工具扩展入口分散”，而是“同一工具在 agent / subagent / workflow 三类运行上下文下重复定义”。因此需要进一步收敛为一套真正的统一定义方式。

## 2. 目标

本需求的目标如下：

- 建立单一工具定义源，使每个工具的元数据、schema、权限需求、执行适配器和展示摘要只定义一次
- 让主 Agent、子代理、workflow worker 不再各自拼装工具 schema，而是从统一定义源解析出当前上下文允许使用的工具集
- 让角色、工作流、会话设置表达“允许哪些工具”时使用统一引用方式，而不是继续依赖分散的布尔字段和手写构建逻辑
- 让工具定义与工具授权解耦：定义负责描述工具，策略负责决定谁在何时可见、可调用
- 为后续 MCP、外部插件、工具市场或更多 workflow 模板预留稳定接入面

## 3. 不在本次范围

- 不要求本期重写所有工具的底层执行实现
- 不要求本期完成完整插件市场或在线安装系统
- 不要求本期重做所有设置页 UI，只要求底层定义和解析方式统一
- 不要求本期把 workflow 编排逻辑整体重构为新的调度模型
- 不要求本期移除现有工具调用记录、时间线和消息展示机制
- 不要求兼容旧工具定义路径或保留渐进迁移过渡层

## 4. 现状问题定义

### 4.1 同一工具存在多份 schema 文本

当前 `str_replace_based_edit_tool`、`bash`、`web_search`、`web_fetch` 至少分别出现在以下位置：

- `ClaudeService+ToolBuilder`
- `ClaudeService+Subagent`
- `WorkflowAgentRunner.WorkflowToolStub`

这些定义看起来相似，但并非完全一致。例如 `bash` 在不同入口的描述、字段集合和交互说明已经出现分叉。继续演进会导致模型在不同上下文下看到的是“同名但不同语义”的工具。

### 4.2 角色能力表达过于底层，无法直接复用

`WorkflowRoleDefinition` 当前通过以下布尔字段表达工具能力：

- `enableTextEditor`
- `enableBash`
- `enableWebSearch`
- `enableWebFetch`
- `enableStoryMemoryTools`

这种表达方式只能覆盖少数内置工具，而且把“工具目录”压扁成了若干硬编码开关：

- 无法自然表达更细粒度授权，例如 bash 只允许 `background`、文本工具只允许 `view`
- 无法表达一个角色依赖的是某个工具组、某个 schema 版本或某个风险级别
- 新增工具时必须继续给角色模型加布尔字段，模型会不断膨胀

### 4.3 工具定义和可用性判断混在一起

当前工具暴露逻辑通常同时依赖：

- 全局设置开关，例如 `settings.enableWebSearchTool`
- 当前执行上下文，例如 `isSubagent`
- 角色布尔能力，例如 `definition.enableBash`
- 特殊路径过滤，例如 story memory 工具通过名称前缀筛选

这让“工具是什么”和“工具现在是否应该暴露”混在同一段构建代码里，导致策略不可组合、不可观察，也不利于测试。

### 4.4 workflow 与 subagent 共享角色名，但不共享完整工具定义模型

当前 `WorkflowRoleDefinition` 已经被 `run_subagent` 和 workflow runtime 共同使用，这是正确方向。但它仍只共享“角色声明”，没有共享“工具定义对象本身”。最终结果是：

- 角色定义是一套
- 工具 schema 组装却仍是多套
- workflow 工件契约和工具契约仍未汇合到同一个注册中心

### 4.5 新增工具或修改字段时缺少单点变更能力

期望状态应该是：新增工具时，只需要新增一份定义，并把它挂到允许的上下文或角色上。

当前状态是：

- 新增工具需要补主 Agent 构建逻辑
- 如需子代理使用，还要补子代理构建逻辑
- 如需 workflow 使用，还要补 workflow stub
- 如需设置页展示，还要补另一套展示映射

这会直接提高维护成本，也会降低上线信心。

## 5. 总体方案

### 5.1 核心原则

- 单一真源：同一个工具的名称、描述、schema、版本、权限、输出摘要规则只能定义一次
- 上下文解析：Agent / Subagent / Workflow 不再手写工具列表，而是声明需求，由统一解析器产出最终可调用工具集
- 定义与授权分离：工具定义不负责判断“谁可用”，授权策略不重复定义工具 schema
- 可扩展：同一套定义模型同时兼容内置工具、桥接工具、MCP 工具、插件工具
- 可观测：系统能够解释某个上下文为什么看到了某些工具，为什么没看到另一些工具

### 5.2 目标形态

系统需要建立三层统一抽象：

1. `ToolDefinition`
定义工具自身的静态信息：ID、展示名、描述、schema、版本、风险、能力需求、输出摘要器、执行适配器标识。

2. `ToolCatalog` / `ToolRegistry`
作为唯一注册中心，保存全部工具定义，并提供查询、版本选择、兼容校验和按条件过滤能力。

3. `ToolsetResolver`
根据当前上下文解析最终工具集。输入包括：当前运行主体、角色、workflow、会话设置、权限中心、实验开关。输出是“当前这次调用实际可用的工具列表”和对应原因说明。

在该模型下：

- 主 Agent 只声明“基础工具域 + 用户启用项 + 非递归限制”
- 子代理只声明“角色工具策略”
- workflow worker 只声明“当前 role / workflow policy”
- 工具 schema 永远从 `ToolRegistry` 读取，不允许在构建路径中重新手写
- 由于应用尚未上市，新方案可以直接替换现有重复定义路径，不需要设计兼容旧结构的中间层

## 6. 功能需求

### 功能点 1：建立统一工具定义对象

需求：

- 每个工具必须对应一个统一的 `ToolDefinition` 或等价模型
- `ToolDefinition` 至少包含以下字段：
  - `id`
  - `displayName`
  - `description`
  - `category`
  - `schemaVersion`
  - `inputSchema`
  - `outputContractSummary`
  - `riskLevel`
  - `requiredCapabilities`
  - `supportedContexts`
  - `executorKey` 或等价执行绑定信息
- 同一个工具的 Anthropic `MessageParameter.Tool` 转换逻辑必须来自该定义对象，不允许在多个入口重复拼装

### 功能点 2：建立统一工具注册中心

需求：

- 系统必须提供唯一的工具注册中心，例如 `ToolRegistry`
- 所有内置工具都必须在注册中心完成注册
- 主 Agent、子代理、workflow runtime 构建工具列表时，只能从注册中心读取
- 注册中心必须支持：
  - 按 `toolId` 查找
  - 按分类或标签筛选
  - 按 schema 版本查询
  - 按上下文能力筛选
  - 返回缺失定义或版本不兼容错误

### 功能点 3：以“工具引用”替代分散布尔开关

需求：

- `WorkflowRoleDefinition` 不应继续以 `enableTextEditor`、`enableBash` 这类字段作为长期主表达方式
- 角色、Agent、Workflow 应改为声明以下任一等价结构：
  - 明确的 `toolIDs`
  - `toolGroups`
  - 带约束的 `ToolGrant`
- `ToolGrant` 最低需要支持：
  - 工具 ID 或工具组 ID
  - 权限级别
  - 参数约束或子集能力
  - 是否允许写操作
  - 是否允许在子代理或 workflow 内继续暴露

示例目标语义：

- `planner` 引用只读文件工具组，而不是 `enableTextEditor = true`
- `explorer` 引用只读文件工具组 + Web 工具组
- `coder` 引用读写文件工具组 + bash 工具组
- `reviewer` 不需要写文件工具，只需要只读工具组

### 功能点 4：统一上下文解析机制

需求：

- 系统必须提供统一的工具解析器，例如 `ToolsetResolver`
- 解析器输入至少包括：
  - 运行上下文类型：main agent / subagent / workflow worker / system workflow
  - 当前角色定义
  - 当前 workflow 定义
  - 用户设置开关
  - 权限中心结果
  - 实验开关或 feature flag
- 解析器输出至少包括：
  - 最终可调用工具列表
  - 每个工具的暴露来源
  - 每个未暴露工具的排除原因

排除原因最低要求：

- `disabledByUserSettings`
- `notGrantedByRole`
- `notSupportedInContext`
- `permissionDenied`
- `dependencyUnavailable`
- `versionConflict`

### 功能点 5：统一 Agent / Subagent / Workflow 的工具接入方式

需求：

- `ClaudeService+ToolBuilder.buildTools(...)` 不再直接手写各工具 schema，而是调用统一注册中心和解析器
- `ClaudeService+Subagent.buildSubagentTools(...)` 不再维护独立 schema 文本，而是基于角色 grants 解析
- `WorkflowAgentRunner.WorkflowToolStub` 应被移除或退化为注册中心适配层，不得继续作为独立工具定义源
- workflow 内新增的专用工具，例如 `emit_workflow_artifact`，也必须进入统一注册中心，而不是作为运行时私有拼装例外长期存在

### 功能点 6：支持工具组与策略模板

需求：

- 系统必须支持“工具组”概念，用于减少角色配置重复
- 工具组至少支持以下类型：
  - 只读文件工具组
  - 读写文件工具组
  - Web 工具组
  - Shell 工具组
  - Story Memory 工具组
  - Workflow 工件工具组
- 系统必须支持策略模板，例如：
  - `mainAgentDefault`
  - `subagentReadOnly`
  - `workflowCoder`
  - `workflowReviewer`
- 模板本身也必须基于工具引用组合，而不是复制 schema

### 功能点 7：支持参数级约束与模式裁剪

需求：

- 统一定义方式不能只解决“有没有这个工具”，还必须支持“同一个工具在不同上下文下能力不同”
- 系统必须支持基于 grant 或 resolver 对工具 schema 做受控裁剪

最低支持场景包括：

- 文本编辑工具在某些角色下只允许 `view`
- bash 工具在某些角色下不允许 `background` 或 `interactive`
- Web 工具在某些 workflow 中只能查询，不允许抓取
- 某些高风险工具只允许主 Agent 使用，不允许 subagent 使用

说明：

- 裁剪后的 schema 仍必须来源于同一个 `ToolDefinition`
- 不允许通过重新复制一份“简化版工具 schema”来实现模式差异

### 功能点 8：统一执行绑定与结果契约

需求：

- 工具执行分发必须通过统一的 `toolId` 绑定到执行器，而不是依赖散落的字符串分支长期扩张
- 工具定义必须声明其执行器类型，例如本地内置、workflow 内部、桥接协议、外部插件
- 工具结果必须能够返回统一结构化摘要，至少支持：
  - 成功 / 失败状态
  - 用户可读摘要
  - 原始 payload
  - 可选附件或 artifact 引用
  - 重试建议

### 功能点 9：统一可观测性与设置展示

需求：

- 设置页或调试页必须能够从同一注册中心读取工具目录，而不是自行维护展示模型
- Tool Call 详情至少应能显示：
  - 工具 ID
  - schema 版本
  - 来自哪个 grant / group / policy 被暴露
  - 当前执行上下文
- 系统必须支持回答以下问题：
  - 为什么 `coder` 看得到 `bash`
  - 为什么 `reviewer` 看不到写文件能力
  - 为什么某个用户关闭了 Web Search 后 workflow 里也不可见

### 功能点 10：一次性收敛实施要求

需求：

- 新架构应以统一注册中心为唯一真源，直接替换当前重复定义路径
- 本期实现完成后，以下重复定义点不应继续保留：
  - `ClaudeService+Subagent.buildSubagentTools(...)` 中的独立 schema 文本
  - `WorkflowAgentRunner.WorkflowToolStub.buildTools()` 中的独立 schema 文本
  - 角色层持续扩张的布尔工具开关
- 若某些旧实现暂时仍存在，也只能作为执行器封装细节存在，不能继续承载工具定义职责

## 7. 数据模型与接口建议

以下为建议方向，不要求字段名完全一致，但语义必须覆盖：

```swift
struct ToolDefinition: Sendable {
    let id: String
    let displayName: String
    let description: String
    let category: ToolCategory
    let schemaVersion: Int
    let baseInputSchema: ToolInputSchema
    let supportedContexts: Set<ToolContext>
    let requiredCapabilities: Set<ToolCapability>
    let riskLevel: ToolRiskLevel
    let executorKey: ToolExecutorKey
}

struct ToolGrant: Sendable {
    let toolID: String
    let accessMode: ToolAccessMode
    let parameterPolicy: ToolParameterPolicy
    let allowedContexts: Set<ToolContext>
}

protocol ToolRegistry {
    func definition(for id: String) -> ToolDefinition?
    func allDefinitions() -> [ToolDefinition]
}

protocol ToolsetResolver {
    func resolve(in request: ToolResolutionRequest) throws -> ToolResolutionResult
}
```

关键要求：

- `ToolDefinition` 负责定义工具本体
- `ToolGrant` 负责表达角色或策略如何引用工具
- `ToolsetResolver` 负责把定义、设置和权限合并为最终暴露结果

## 8. 验收标准

- 新增一个内置工具时，只需要新增一份工具定义，并在角色或策略层增加引用，不需要在主 Agent / 子代理 / workflow 三处重复写 schema
- 修改一个已有工具的字段说明或 schema 时，所有上下文自动同步，不允许出现多份手写文本分叉
- `planner`、`explorer`、`coder`、`reviewer`、`executor` 的工具集能够通过统一 grant 机制表达，不再依赖持续膨胀的布尔字段
- workflow runtime 不再保留独立的工具 stub 定义作为长期真源
- 设置页、调试视图、Tool Call 详情能够直接读取统一工具目录并展示版本、授权来源和不可用原因
- 系统能够对某个上下文输出完整解析结果，包括已暴露工具与未暴露原因
- 不要求为了兼容旧结构而同时维护新旧两套工具定义路径

## 9. 优先级

- P0：统一 `ToolDefinition`、`ToolRegistry`、`ToolsetResolver` 三层抽象；移除主 Agent / subagent / workflow 的重复 schema 定义
- P1：以 `ToolGrant` / 工具组替换角色布尔开关；支持参数级裁剪和上下文限制
- P2：设置页统一目录展示、调试可观测性、外部插件 / MCP 适配入口

## 10. 后续实施建议

建议后续直接基于本需求再输出一份实现计划，拆成以下三个阶段：

1. 先收敛定义层：建立 `ToolDefinition`、注册中心和 Anthropic tool 转换器
2. 再收敛授权层：让角色、workflow、主 Agent 全部改为声明式 grants
3. 最后收敛展示层：统一设置展示和调试信息