# Skill 执行、长上下文保持与多技能编排调研报告

日期：2026-03-13

关联对象：`SkillService`、`Skill`、`ACPClientService.resolveTurnSkillContext(...)`、`ACPClientService.buildSystemPrompt(...)`、`WorkflowWorkspaceContext.availableSkills`、`WorkflowAgentRunner.buildTask(...)`、`run_subagent`、`read_skill`

## 1. 调研目标

本报告聚焦四个直接问题：

- 如何让 Agent 更稳定地遵循 skill 定义执行，而不是只把 skill 当作提示词附件
- 如何在长上下文、多轮工具调用和多窗口续跑中避免“忘记 skill 内容”
- 如何处理 skill 之间的相互引用、依赖、冲突与组合
- 如何让多个 skill 可以同时启用，并在运行时形成统一、可解释、可评估的执行策略

本报告同时要求把外部调研结论映射到当前工程现状，给出一套可落地的演进方案，而不是停留在抽象建议。

## 2. 执行摘要

结论非常明确：如果要把 skill 做成一等公民，系统不能继续把 skill 主要视为“可读 Markdown 文档”。当前实现已经具备技能扫描、启用、显式激活和按需读取能力，但整体仍属于“prompt 资源层”，还没有进入“运行时控制层”。

成熟做法更接近以下形态：

- 用结构化 manifest 描述 skill 的触发条件、权限、依赖、输出契约和检查项
- 用路由器在每一轮动态决定哪些 skill 应该激活、哪些应该忽略、哪些必须强制生效
- 用短小的 Active Skill Card 常驻上下文，而把完整 skill 正文改为按需检索
- 用状态对象、压缩后再水化和回合末合规检查，替代“希望模型一直记得最开始那段技能正文”
- 用显式依赖图和组合器解决 skill 之间的引用、冲突与多技能共存问题

如果继续依赖“把 skill 名称与描述放进系统提示，需要时再 `read_skill` 一次”的模式，系统在任务变长、工具调用增多、角色变多、技能数增长后，会稳定遇到四类问题：

- 触发不稳定：该用 skill 时没用，不该用时乱用
- 遵循漂移：前几轮遵循，后几轮逐渐偏离 skill 要求
- 上下文退化：skill 正文被更近、更长、更相关的工具结果淹没
- 多技能冲突：两个 skill 都“看起来有道理”，但系统没有统一优先级和合成逻辑

因此，本报告建议把 skill 体系升级为四层结构：声明层、解析层、执行层、评估层。

## 3. 当前工程现状

从现有代码看，项目已经有以下能力：

### 3.1 技能发现与读取

`SkillService` 负责扫描本地 skill 目录、解析 frontmatter、缓存正文，并提供 `readSkillContent(name:)` 能力。

这说明项目已经有本地 skill registry 的雏形，但注册信息仍然偏轻，只包含：

- `directoryName`
- `name`
- `description`
- `path`
- `contentURL`

这不足以支持运行时路由、依赖解析、冲突检测、权限控制或质量评估。

### 3.2 Turn 级别技能启用

`ACPClientService.resolveTurnSkillContext(...)` 已经支持两类技能来源：

- 全局启用技能
- 通过 slash 或输入指令显式激活的技能

这解决了“技能可见性”和“技能临时启用”的基础问题，但返回值仍然只有 `effectiveSkills` 和 `explicitlyActivatedSkills`，没有：

- 激活原因
- 技能优先级
- 技能组合结果
- 技能冲突信息
- 技能检查项
- 技能工具策略

因此，系统只能表达“有哪些 skill”，不能表达“当前为什么要用这些 skill、它们怎样共同约束执行”。

### 3.3 Prompt 注入方式

当前 `buildSystemPrompt(...)` 会：

- 列出可用技能及其描述
- 对显式激活技能内联完整正文

这个设计在技能数量较少时足够直接，但存在两个问题：

第一，显式激活技能全文注入会显著抬高上下文成本。

第二，技能正文出现在系统提示的固定位置，后续多轮工具结果、大量文件内容和中间产物会逐步淹没这些约束。长任务里，这类一次性注入最容易发生“前面看过，后面忘掉”。

### 3.4 Workflow 中对 skill 的表达仍然偏弱

`WorkflowWorkspaceContext` 目前只保留 `availableSkills: [WorkflowSkillInfo]`，内容只有技能名称和描述。`WorkflowAgentRunner.buildTask(...)` 在 worker prompt 中也仅渲染技能名字和一句描述。

这意味着：

- workflow worker 无法得到技能正文中的关键执行规则
- role 级别无法拿到与自己强相关的 skill 约束
- skill 还没有进入调度、产物要求、回合预算和验证闭环

因此，当前设计更像“让 workflow 知道系统里有 skill”，还不是“让 workflow 真正受 skill 约束”。

## 4. 外部调研结论

### 4.1 Anthropic 文档结论

Anthropic 在工具、prompt、长上下文和 agent 工作流上的公开建议高度一致：

- 工具和能力应该有清晰、低歧义、可测试的契约
- 长任务不要依赖一次性大 prompt，而应依赖结构化状态和可恢复上下文
- 多步任务适合 routing、orchestrator-workers、evaluator-optimizer 等组合模式
- 长上下文不是越长越好，必须控制放进上下文的内容质量和位置

与本议题最相关的要点有：

- Prompt 需要清晰、分段、结构化，适合用 XML 或明确 section 表达
- 长上下文任务中，文档和大段上下文应放在前部，真正要回答的问题放在后部
- 长窗口工作流要把状态写入结构化产物，在压缩或新窗口后重新恢复
- 对工具和子代理的使用要有明确边界与文档，而不是笼统鼓励“多用工具”

这直接支持本报告的核心判断：skill 不应该长期以“全文常驻”的方式存在，而应拆成可检索、可组合、可再水化的结构化能力对象。

### 4.2 Lost in the Middle

论文《Lost in the Middle》指出，在长上下文场景下，模型对位于长输入中部的信息利用率显著下降，性能在相关信息位于开头或结尾时更高，位于中间时更差。

这对 skill 系统有直接含义：

- 不能把关键 skill 约束只注入一次，然后假设模型能一直记住
- 不能把多个 skill 全文堆进系统提示中部，期待后续几十轮还稳定生效
- 必须把高优先级 skill 约束转成短小、重复可见、位置靠后或任务前置的执行卡片

### 4.3 RAG 与 MemGPT

RAG 说明知识密集型任务更适合“参数记忆 + 外部检索记忆”的组合；MemGPT 说明长任务更适合做分层记忆与上下文换入换出，而不是试图让所有知识永驻主上下文。

对 skill 系统的启发是：

- skill 正文应该视为外部可检索记忆，而不是默认常驻内存
- skill 的摘要、状态和当前义务应进入短期工作记忆
- skill 的完整正文、例子、扩展说明应进入可检索层
- 多窗口任务中，必须保留“当前活跃技能状态”，而不是仅保留过去对话文本

### 4.4 Toolformer 与 ReAct

Toolformer 说明模型可以学习何时调用外部工具；ReAct 说明推理和行动交错时系统更可解释、也更稳健。

这两点对应到 skill 的含义是：

- skill 不应只是“读一段文档”，还应参与“决定何时用什么能力”
- skill 约束不能只在回答前给一次，而应在计划、行动、读工具结果和修正路径时重复参与

### 4.5 Self-Refine

Self-Refine 证明，生成、反馈、再修正的简单循环就能显著提高输出质量。

对 skill 系统而言，这支持引入“Skill Compliance Check”：

- 先执行
- 再检查是否遵循 active skills
- 不符合时给出结构化反馈
- 再做最小回修

这比单纯相信系统提示更可靠。

## 5. 关键设计判断

### 5.1 Skill 不是文档，而是 capability contract

本项目后续不应把 skill 主要建模为“一个目录 + 一个 SKILL.md 文件”。更准确的定义应是：

> Skill 是一个带有触发条件、行为约束、工具策略、依赖声明、输出契约和合规检查项的运行时能力单元。

Markdown 文件仍然可以保留，但只作为技能定义的载体，不再是唯一运行时真源。

### 5.2 Skill 不能仅靠全局开关

全局启用的价值，只在于“允许被发现”。真正决定本轮是否激活 skill 的，必须是动态路由器，而不是单一 settings 开关。

### 5.3 多技能并用必须先合成，再交给 Agent

多个 skill 同时活跃时，运行时要给 Agent 的不应该是三段并列文档，而应该是一份已合成的统一执行计划。否则模型只能自己猜优先级、猜冲突处理方式、猜先后顺序。

## 6. 总体方案

建议把 skill 系统拆成四层。

### 6.1 声明层：Skill Manifest

新增结构化 manifest，建议字段至少包含：

- `id`
- `version`
- `displayName`
- `summary`
- `category`
- `whenToUse`
- `whenNotToUse`
- `preferredRoles`
- `requiredTools`
- `forbiddenTools`
- `dependencies`
- `exports`
- `conflictsWith`
- `priority`
- `activationExamples`
- `complianceChecklist`
- `successCriteria`
- `failureRecovery`
- `maxContextCost`

建议将 skill 分为几类：

- `safety`
- `process`
- `domain`
- `style`
- `tooling`

这会直接影响多技能合成优先级。

### 6.2 解析层：Skill Router 与 Resolver

解析层分为两个组件：

#### 6.2.1 Skill Router

输入：

- 用户请求
- 当前工作区上下文
- 当前 role
- 当前 workflow phase
- 已启用 skill 列表
- 显式激活 skill 列表

输出：`SkillActivationPlan`

推荐字段：

- `requiredSkills`
- `recommendedSkills`
- `optionalSkills`
- `rejectedSkills`
- `activationReasons`
- `conflictDecisions`
- `mergedChecklist`
- `toolPolicyPatch`
- `rehydrationHints`

#### 6.2.2 Skill Resolver

负责：

- 展开 skill 依赖闭包
- 检查循环依赖
- 解析导出片段
- 合并引用内容
- 发现冲突并按优先级裁决

### 6.3 执行层：Active Skill Cards + On-demand Retrieval

#### 6.3.1 Active Skill Cards

每个激活 skill 不再默认把全文塞进 prompt，而是先压缩成一张执行卡。建议包含：

- skill 名称
- 激活原因
- 三到五条必须遵守规则
- 两到三条禁止事项
- 相关工具建议
- 完成条件

这些卡片应作为当前 turn 或当前 worker 的常驻技能上下文。

#### 6.3.2 Skill Full Text / Section Retrieval

保留完整 skill 正文，但改为按需读取：

- `read_skill_full(skillID)`
- `read_skill_section(skillID, sectionID)`
- `resolve_skill_bundle(skillIDs)`

与当前仅支持 `read_skill(name)` 相比，这样可以更细粒度地控制上下文成本。

### 6.4 评估层：Skill Compliance

每一轮执行结束后引入 `SkillComplianceCheck`。输入包括：

- 当前 active skills
- 本轮工具调用轨迹
- 本轮输出
- 当前 workflow artifact

输出包括：

- `passed`
- `violations`
- `missingSteps`
- `suggestedRepair`

当发现技能违规时，不直接静默继续，而是：

- 在本轮内做最小回修
- 或在 workflow 中把结果发给 verifier 角色再回流

## 7. 如何防止上下文过长时忘记 skill 内容

这是本报告最关键的问题之一。建议采用四层机制共同解决。

### 7.1 用短卡常驻，全文按需回灌

最重要的 skill 规则必须用短卡常驻上下文；完整正文只在需要细节时读取。这样既减少 token 成本，也降低技能正文被中部淹没的概率。

### 7.2 关键动作前做局部再注入

在以下关键节点，系统应把当前 active skill 中最相关的片段重新注入：

- 准备调用 shell 前
- 准备编辑文件前
- 准备发起 web research 前
- 准备结束回答前
- workflow 角色切换后

这不是重复整篇 skill，而是仅回灌当前动作最相关的 checklist 片段。

### 7.3 把技能状态外置成结构化对象

建议新增 `SkillExecutionState`，至少记录：

- `activeSkillIDs`
- `activationPlanVersion`
- `unmetChecklistItems`
- `waivedChecklistItems`
- `lastRehydratedAt`
- `evidenceRefs`

这样系统在多轮后可以重新恢复“当前仍在生效的技能义务”，而不是依赖早期 prompt 文字仍留在上下文里。

### 7.4 在压缩或新窗口后执行 Skill Rehydration

上下文压缩或新窗口恢复时，不应只恢复任务摘要。必须专门恢复一份技能状态包，建议包含：

- 当前任务概述
- 当前 workflow phase
- 当前 active skills
- 每个 active skill 的一句激活原因
- 尚未满足的 checklist
- 最近一次技能违规点
- 下一步建议

这份 rehydration 包应该短、结构化、可直接被下一个上下文窗口消费。

## 8. 如何处理 skill 的相互引用

建议从“文档互相提到对方”升级成显式依赖图与导出片段系统。

### 8.1 显式 imports / exports

每个 skill 可以声明：

- `imports`: 依赖别的 skill 的哪些片段
- `exports`: 对外暴露哪些片段

示例：

- `brainstorming` 导出 `planning.discovery-checklist`
- `test-driven-development` 导出 `coding.test-first-checklist`
- `swiftui-expert-skill` 导出 `ui.swiftui-quality-rules`

### 8.2 引用片段而非全文

skill 之间不允许默认引用整个 skill 正文，只允许引用具名 section 或导出片段。原因是：

- 全文展开容易导致上下文爆炸
- 全文展开难以追踪真正依赖了什么
- 全文展开更容易引入循环引用和冲突

### 8.3 依赖解析规则

Skill Resolver 需要支持：

- 依赖闭包展开
- 重复依赖去重
- 循环依赖检测
- 缺失依赖诊断
- 版本兼容校验

一旦出现循环依赖或无法解析，系统应给出显式错误，而不是静默跳过。

### 8.4 命名空间与优先级

导出片段必须具备命名空间，例如：

- `planning.discovery-checklist`
- `coding.test-first`
- `ui.swiftui-review-rules`
- `answer.report-format`

冲突解析建议按以下优先级：

- `safety` 高于 `process`
- `process` 高于 `domain`
- `domain` 高于 `style`
- `style` 高于 `tooling` 的表层偏好

## 9. 如何同时使用多种技能

多技能并用的关键不是“同时激活很多个 skill”，而是“把多个 skill 合成成一个统一的执行平面”。

### 9.1 技能分类组合

建议多技能组合按以下类别进行：

- `safety`: 决定什么不能做、什么需要确认
- `process`: 决定工作顺序，例如先调研、先写测试、先计划
- `domain`: 决定专业知识和评审标准
- `style`: 决定输出形态和表达偏好
- `tooling`: 决定偏好使用哪些工具和调用形式

### 9.2 组合器输出物

Skill Composer 最终不应输出一堆并列文本，而应输出三类产物：

- `mergedExecutionPrinciples`
- `mergedToolPolicy`
- `mergedChecklist`

这样 Agent 拿到的是统一规则，而不是需要自己在多份技能文案之间做仲裁。

### 9.3 示例：三技能并用

如果同时启用：

- `brainstorming`
- `test-driven-development`
- `swiftui-expert-skill`

合成结果应接近：

- 先澄清需求与边界
- 再建立测试或验证基线
- 再进行 SwiftUI 实现
- 实现过程中遵循 SwiftUI 专项质量规则
- 最终输出同时满足测试、设计和行为规范

而不是简单把三份正文串起来。

## 10. 如何让 Agent 更稳定遵循 skill 定义执行

建议使用三段式执行闭环。

### 10.1 执行前：Plan with Skills

在真正行动前，先生成技能驱动的执行计划。计划至少要回答：

- 当前激活了哪些 skill
- 每个 skill 为什么被激活
- 本轮关键义务是什么
- 本轮禁止事项是什么
- 本轮预期工具路径是什么

### 10.2 执行中：Action Gating

技能不应只影响语言输出，也应影响行动层：

- 调整可见工具的排序或推荐程度
- 对高风险工具做额外确认
- 在某些 skill 下强制先调用某类工具
- 对输出格式做 schema 约束

也就是说，skill 需要能 patch tool policy，而不是只 patch prompt。

### 10.3 执行后：Compliance Review

输出前或回合结束时必须检查：

- 是否遗漏 skill 要求的关键步骤
- 是否使用了禁止工具
- 是否输出了要求的结构化产物
- 是否满足 skill 的完成标准

如果失败，应以最小回修循环修正，而不是无声漂移。

## 11. 对当前工程的落地建议

### 11.1 数据模型改造

建议新增：

- `SkillManifest`
- `SkillDependency`
- `SkillExport`
- `SkillActivationPlan`
- `ActiveSkillCard`
- `SkillExecutionState`
- `SkillComplianceResult`

现有 `Skill` 可保留为发现层对象，用于目录扫描和基础元数据。

### 11.2 SkillService 升级方向

`SkillService` 不应继续只是“扫描 + 读全文 + 缓存”，而应升级为 skill registry，负责：

- manifest 解析
- 正文 section 解析
- 导出片段索引
- 依赖图构建
- 激活时快速获取技能卡

### 11.3 ACPClientService 升级方向

`resolveTurnSkillContext(...)` 建议升级为 `resolveSkillActivationPlan(...)`，返回的不是简单 skill 列表，而是完整 activation plan。

`buildSystemPrompt(...)` 则应改为：

- 注入少量 Active Skill Cards
- 在显式激活情况下最多内联关键片段，而不是整篇正文
- 把完整技能文档变成按需读取能力

### 11.4 WorkflowRuntime / WorkflowAgentRunner 升级方向

`WorkflowWorkspaceContext.availableSkills` 目前太轻，建议升级为：

- `availableSkillIDs`
- `recommendedSkillsByRole`
- `activationHints`

`WorkflowAgentRunner.buildTask(...)` 不应只列 skill 名称与描述，而应针对当前 role 渲染：

- role-relevant active skills
- 当前 role 必须遵守的技能卡
- 当前 role 的技能输出契约

### 11.5 Tool Dispatch 升级方向

建议增加更细粒度的 skill 工具：

- `read_skill_section`
- `resolve_skill_bundle`
- `verify_skill_compliance`

这样后续可以减少整篇 skill 注入，提高上下文利用效率。

## 12. 分阶段实施建议

### Phase 1：最小闭环

目标：先把 skill 从“可见”变成“可执行”。

建议内容：

- 增加 `SkillManifest`
- 增加 `SkillActivationPlan`
- 增加 `ActiveSkillCard`
- `buildSystemPrompt(...)` 改为优先注入技能卡
- 增加基础 `SkillComplianceCheck`

### Phase 2：依赖与组合

目标：让多个 skill 可以稳定共存。

建议内容：

- 增加 imports / exports
- 增加 `SkillResolver`
- 增加 `SkillComposer`
- 增加冲突和循环依赖检测

### Phase 3：长任务恢复与可观测性

目标：解决长任务中技能遗忘与调试困难。

建议内容：

- 增加 `SkillExecutionState`
- 增加压缩后再水化机制
- 增加技能事件 telemetry
- 在 UI 中展示激活原因、依赖关系和违规记录

## 13. 评估指标

本方案落地后，建议至少跟踪以下指标：

- 该触发的 skill 命中率
- 不该触发的 skill 误触发率
- 多技能任务的一次成功率
- 长任务中技能违规率
- 技能回修次数
- 平均上下文成本
- 平均 `read_skill` / `read_skill_section` 次数
- 用户显式重申技能要求的频率

如果没有这套指标，后续只能靠主观感受判断 skill 是否有效。

## 14. 风险与边界

### 14.1 过度结构化风险

如果把 skill schema 设计得过重，维护成本会急剧上升。应优先保证最小字段集可闭环，不要一开始就把所有潜在字段全部引入。

### 14.2 过度并行或过度组合风险

技能过多时，系统可能出现“为了组合而组合”的问题。组合器必须有限制，必要时只保留高优先级技能进入本轮执行面。

### 14.3 过度提示风险

Anthropic 文档明确提醒，新的模型对系统提示和工具触发更敏感。skill 卡片必须简洁、直接、少重复，否则容易造成工具过触发和思考过载。

## 15. 结论

当前项目的 skill 体系已经完成了“发现、启用、显式激活、按需读取”的第一阶段建设，但距离“一等公民”还有明显差距。要真正解决 skill 遵循性、长上下文遗忘、相互引用和多技能并用问题，必须把 skill 从 Markdown 指南升级成运行时能力合同。

这意味着后续的核心改造方向不是“再写更多 skill”，而是：

- 建立结构化 skill manifest
- 建立 activation plan 与组合器
- 用 Active Skill Cards 替代全文常驻
- 在长任务中做状态外置与再水化
- 用 compliance loop 把 skill 从软约束变成可验证约束

只有完成这几步，skill 才会从提示词资产变成系统级能力。

## 16. 参考资料

- Anthropic, Building effective agents: https://www.anthropic.com/engineering/building-effective-agents
- Anthropic, Prompting best practices: https://platform.claude.com/docs/en/docs/build-with-claude/prompt-engineering/system-prompts
- Anthropic, Context windows: https://platform.claude.com/docs/en/docs/build-with-claude/context-windows
- Anthropic, Tool use with Claude: https://platform.claude.com/docs/en/docs/agents-and-tools/tool-use/overview
- Model Context Protocol introduction: https://modelcontextprotocol.io/introduction
- Toolformer: Language Models Can Teach Themselves to Use Tools: https://arxiv.org/abs/2302.04761
- ReAct: Synergizing Reasoning and Acting in Language Models: https://arxiv.org/abs/2210.03629
- Lost in the Middle: How Language Models Use Long Contexts: https://arxiv.org/abs/2307.03172
- Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks: https://arxiv.org/abs/2005.11401
- MemGPT: Towards LLMs as Operating Systems: https://arxiv.org/abs/2310.08560
- Self-Refine: Iterative Refinement with Self-Feedback: https://arxiv.org/abs/2303.17651