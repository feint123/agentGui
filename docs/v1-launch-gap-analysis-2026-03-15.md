# agentGui 首版上线缺口分析与需求文档

日期：2026-03-15

## 1. 文档目的

本文档用于从“首版正式上线”视角，重新评估 agentGui 当前代码基线与产品闭环情况，明确：

1. 当前已经具备哪些可作为 v1 基础盘的能力。
2. 各模块还缺失哪些“基础功能”或“上线前必须补齐的产品闭环”。
3. 哪些事项应归为 P0 / P1 / P2。
4. 后续需求拆分时，应优先做哪些最小必要补齐，而不是继续扩展高级玩法。

这里的“缺口”只讨论对首版交付有直接影响的能力，不把更远期的高级自动化、复杂工作流扩展、深层记忆策略迭代当作当前上线前提。

## 2. 本次核查依据

本次分析基于以下事实进行：

1. 核查了当前主 UI、设置、聊天、工作区、Git、工具、工作流、记忆、恢复等核心模块代码。
2. 实际执行了完整构建：`xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build`，结果为 `BUILD SUCCEEDED`。
3. 实际执行了仓库提供的 `./scripts/run_quality_smoke.sh`，结果为 `TEST SUCCEEDED`。
4. 同时，VS Code Problems 仍报告大量 LSP / Memory 相关静态错误，说明当前工程存在“正式 build 通过，但工作区索引 / 非主链文件状态不干净”的一致性问题。这不等同于当前 build blocker，但属于发版前必须澄清的工程健康风险。

## 3. 当前结论

当前 agentGui 已经具备首版产品的核心技术主链：

1. 可运行的 macOS 原生三栏工作区 + 聊天界面。
2. Claude 流式消息、Agent Loop、多轮工具调用、Todo、子代理、工作流、Git / 工作区上下文注入。
3. 设置页、技能页、诊断中心、恢复 Banner、备份导出、RMS 面板等基础产品面。
4. 一套已能跑通 focused smoke 的质量基线。

但如果按“能否对外发布并让首批用户稳定完成一次真实任务”来衡量，当前仍缺少几类基础闭环：

1. 首次启动与首次配置闭环不完整。
2. 工作区与 Git 仍偏“只读观察”，缺少最基本的操作闭环。
3. 备份、恢复、技能管理、文件管理等能力有底层实现，但缺少用户可达入口。
4. 发布与工程健康层面仍缺少正式 release 交付约束与清理动作。

## 4. 优先级定义

- P0：不补齐就不建议首版上线，或会直接影响首批用户完成核心任务 / 正式发布。
- P1：建议在首版上线前补齐，否则会明显拉低可用性、恢复能力、可理解性或运维成本。
- P2：不是首版阻塞项，但应进入首版后首轮迭代。

## 5. 模块级差距分析

### 5.1 App Shell 与首启体验

当前已有：

1. `ContentView` 提供 `对话 / Skills / 诊断` 三个一级 Tab。
2. `SettingsWindowView` 已提供独立设置窗口与分区导航。
3. `ChatView` 会在未配置 API Key 时显示导航副标题“请先配置 API Key”。

代表性证据：

- `agentGui/ContentView.swift`
- `agentGui/Views/MainSplitView.swift`
- `agentGui/Views/Settings/SettingsWindowView.swift`
- `agentGui/Views/ChatView.swift`

缺失项：

1. P0：缺少首启引导页或首启向导。
   现状是应用直接进入主界面，用户需要自己发现 `Cmd+,` 或菜单里的“设置...”，才能完成首轮配置。对首批外部用户不够直接。
2. P0：缺少“未完成配置时的显式主操作引导”。
   当前只有副标题提醒和发送时报错，没有在空态中给出“去设置”“填入 API Key”“选择工作目录”的显式 CTA。
3. P1：缺少“首次成功任务路径”的产品引导。
   没有告诉用户第一步该怎么做，比如“配置 API Key -> 选择工作目录 -> 启用工具 -> 发出第一个任务”。
4. P1：缺少“版本 / 变更 / 已知限制”的用户可见入口。
   首版上线时至少应让用户知道 Bash、LSP、记忆、工作流分别属于什么稳定度。

上线要求：

1. 新用户第一次启动时，必须能在 1 到 2 步内完成 API Key 配置。
2. 空会话状态中应直接提供“打开设置”“选择工作目录”“查看示例提示词”操作。
3. 明确展示当前关键能力的启用前提和限制。

### 5.2 会话与聊天主链路

当前已有：

1. 会话创建、切换、删除、清空。
2. 流式消息、重新生成、编辑后重发、消息删除、从此处截断重来。
3. 文件上下文、选区上下文、拖拽附件、Slash 指令、Todo 卡片、停止生成。

代表性证据：

- `agentGui/Views/ChatView.swift`
- `agentGui/Views/ChatView+Actions.swift`
- `agentGui/Views/ChatView+InputArea.swift`
- `agentGui/Views/ChatView+Toolbar.swift`
- `agentGui/Services/ClaudeService+Messaging.swift`

缺失项：

1. P0：缺少“聊天空态到首条成功消息”的明确引导。
   新建会话后虽然有“开始对话”空态，但没有告诉用户如果未配置模型 / 工具 / 工作目录时下一步该做什么。
2. P1：缺少会话重命名入口。
   当前标题主要依赖首条消息自动生成，没有显式手动重命名入口，不利于长期整理。
3. P1：缺少输入草稿保存。
   当前输入区状态完全是内存态，切换会话或误操作后容易丢失正在编辑的长 prompt。
4. P1：缺少常用提示模板 / 示例任务入口。
   对首版产品尤其重要，否则“会发消息”不等于“会正确使用 Agent”。
5. P2：缺少快捷键帮助与交互提示。
   比如 Slash、@ 文件、附件、停止生成、删除上下文 chip 的可发现性还不够。

上线要求：

1. 新会话空态必须支持“示例任务”“打开设置”“选择工作目录”三类快捷动作。
2. 会话列表或工具栏应支持手动重命名。
3. 输入框应具备最基本的草稿恢复能力。

### 5.3 设置与配置管理

当前已有：

1. 连接、工具、智能、记忆、通用五个设置分区。
2. API Key、Base URL、代理、模型选择。
3. Bash、Web Search、Web Fetch、LSP、Memory、Reflection、Extended Thinking 等开关。

代表性证据：

- `agentGui/Views/Settings/SettingsConnectionView.swift`
- `agentGui/Views/Settings/SettingsToolsView.swift`
- `agentGui/Views/Settings/SettingsIntelligenceView.swift`
- `agentGui/Views/Settings/SettingsMemoryView.swift`
- `agentGui/Models/AppSettings.swift`

缺失项：

1. P2：缺少设置项之间的依赖校验与“配置完成度”提示。
   例如启用了 Web Search 但没有配置可用后端、启用了 LSP 但未绑定工作区，这些状态当前主要靠用户自己理解。
2. P0：缺少“连接测试 / 配置验证”动作。
   仅保存配置还不够，首版上线前应支持主动验证 API Key、Base URL、代理是否可达。
3. P1：缺少“工具启用建议”。
   当前开关很多，但没有根据用户场景推荐最小安全组合，比如普通聊天模式、代码模式、研究模式。
4. P1：缺少“恢复默认值”“导入导出设置”能力。
5. P2：缺少对高风险功能的更清晰风险分层说明。

上线要求：

1. 设置页应能一键验证连接可用性。
2. 设置页顶部应显示当前是否满足“可开始使用”的最小条件。
3. 高风险工具启用时应有更明确的风险文案。

### 5.4 工作区与文件编辑器

当前已有：

1. 工作目录选择、文件树浏览、文件打开与保存。
2. 图片 / PDF 预览、文本编辑、外部修改冲突提示。
3. Markdown 块编辑器、行内格式工具、选区同步到聊天上下文。

代表性证据：

- `agentGui/Views/WorkspacePanelView.swift`
- `agentGui/Views/FileEditorView.swift`
- `agentGui/Views/Editor/BlockDocumentEditor.swift`

缺失项：

1. P0：缺少“新建文件 / 新建文件夹 / 重命名 / 删除”基础文件管理入口。
   当前工作区面板主要是浏览与选择，没有形成最基本的文件操作闭环。
2. P0：缺少文件树搜索 / 过滤。
   项目一旦变大，当前树状浏览效率会迅速下降。
3. P1：缺少最近打开文件、固定文件、快速跳转等基础效率功能。
4. P2：缺少未保存文件切换保护策略的显式 UX 设计。
   当前有脏状态和保存按钮，但对切文件时的体验还比较轻。

上线要求：

1. 用户必须能在应用内完成最基础的文件增删改查闭环。
2. 文件树必须具备名称搜索或快速过滤能力。
3. 文本编辑器在切换文件前应明确处理未保存修改。


### 5.6 工具系统与 Agent 执行能力

当前已有：

1. 文本编辑、Bash、Web Search、Web Fetch、LSP、ask_user_question、todo、workflow、subagent 等主链工具。
2. 大文本结果预算治理、payload store、工具调用详情 UI。
3. 本地图片分析与 PDF 读取在 dispatch 层已有入口。

代表性证据：

- `agentGui/Services/ToolRegistry.swift`
- `agentGui/Services/ClaudeService+ToolDispatch.swift`
- `agentGui/Services/ClaudeService+BashTool.swift`
- `agentGui/Views/ToolCallBubbleView.swift`
- `agentGui/Views/ToolCallDetailContentView.swift`

缺失项：

1. P0：缺少“用户可理解的工具权限模型”。
   当前工具很多，但首版对外时，用户需要清楚知道哪些工具默认启用、哪些会动文件、哪些会执行命令、哪些需要额外配置。
2. P1：缺少“工具不可用原因”的统一解释层。
   例如 Web / LSP / Bash 不可用时，当前更多是执行时报错，而不是在产品面中提前解释。
3. P1：缺少“高风险操作确认策略”的一致性产品表达。
   运行时已有部分安全判断，但用户界面层还没有形成稳定、可预期的风险提示语言。
4. P2：缺少按场景预设工具组合。

上线要求：

1. 工具页必须明确说明每个工具的作用、风险、启用前提。
2. 工具被禁用或不可用时，应直接告诉用户缺什么，而不是只在任务执行中失败。

### 5.7 Skills 模块

当前已有：

1. 扫描 `~/.claude/skills/`。
2. 展示已发现技能，支持启用 / 禁用。
3. 支持刷新技能列表，读取技能内容并注入 prompt。

代表性证据：

- `agentGui/Services/SkillService.swift`
- `agentGui/ContentView.swift` 中的 `SkillsView`

缺失项：

1. P1：缺少技能安装 / 导入入口。
   当前默认假设用户会手动把文件放到 `~/.claude/skills/`，这对首版公开用户不够友好。
2. P1：缺少技能详情预览。
   现在只能看到名称和简短描述，不足以帮助用户判断是否启用。
3. P1：缺少技能健康状态提示。
   例如 frontmatter 错误、资源缺失、路径无效、兼容性问题都没有 UI 反馈。
4. P2：缺少搜索、分类、推荐、示例技能。

上线要求：

1. 至少提供“查看技能详情”和“打开技能目录”能力。
2. 技能解析失败时，UI 应明确告诉用户失败原因。

### 5.8 Memory / RMS 模块

当前已有：

1. Memory 开关与预算设置。
2. 聊天侧 RMS 面板入口。
3. Task-bound RMS 状态与部分持久化、注入主链。

代表性证据：

- `agentGui/Views/Settings/SettingsMemoryView.swift`
- `agentGui/Views/Memory/RMSCognitionPanel.swift`
- `agentGui/Services/RMSPromptComposer.swift`
- `agentGui/Services/SessionTaskStateStore.swift`

缺失项：

1. P0：缺少用户能理解的 Memory 生命周期说明。
   当前设置文案偏实现导向，不够说明“哪些会记住、记多久、如何清理”。
2. P1：缺少 Memory 管理操作。
   例如查看最近写入、删除某条、清空当前会话记忆、导出记忆摘要。
4. P2：缺少更强的可解释性与用户控制面。

上线要求：

1. 用户必须能理解 Memory 是否生效、对当前会话有什么影响。
2. 至少提供查看与清理当前会话 Memory 状态的入口。
3. 发版前应清理或解释当前 Memory 相关静态报错来源。

### 5.9 Workflow 与子代理协作

当前已有：

1. Workflow runtime、timeline、artifact panel、role 状态。
2. 子代理目录、内建 agent、workflow artifact 产物与多角色协作框架。
3. 中断恢复 Banner 与诊断中心联动。

代表性证据：

- `agentGui/Services/WorkflowRuntime.swift`
- `agentGui/Services/WorkflowAgentRunner.swift`
- `agentGui/Views/WorkflowArtifactPanel.swift`
- `agentGui/Views/WorkflowTimelineView.swift`

缺失项：

1. P1：缺少对普通用户足够友好的 workflow 使用入口。
   当前更像是工程能力已在，但缺少“什么时候该开 workflow、什么时候只是普通对话”的产品引导。
2. P1：缺少 workflow 管理动作。
   没有明显的暂停、恢复、终止、重试入口。
3. P1：缺少 artifact 审批 / 采纳的显式交互。
   目前展示了状态，但还没有完整的人机确认闭环。
4. P2：缺少 workflow 历史与模板管理。

上线要求：

1. 对外首版应把 workflow 定位讲清楚，避免用户误把它当“默认聊天模式”。
2. 运行中的 workflow 至少应支持停止和恢复查看。

### 5.10 诊断、恢复与备份

当前已有：

1. 诊断中心展示完整性问题、恢复项、最近保存失败。
2. 支持全量备份导出。
3. 运行时恢复 Banner 已接入聊天页。

代表性证据：

- `agentGui/Views/Reliability/ReliabilityCenterView.swift`
- `agentGui/ViewModels/ReliabilityCenterViewModel.swift`
- `agentGui/Services/RuntimeRecoveryService.swift`
- `agentGui/Services/BackupArchiveService.swift`

缺失项：

1. P1：缺少备份恢复 UI。
   `BackupArchiveService` 已有 `restore` 能力，但诊断中心当前只暴露了导出。
2. P1：缺少更明确的恢复建议。
   现在能看到恢复项，但缺少“为什么发生、下一步怎么做”的解释。
3. P1：缺少错误日志导出。
   对首版外部用户支持和问题排查很关键。
4. P2：缺少自动备份策略与保留策略配置。

上线要求：

1. 诊断中心至少应支持“导出备份”和“从备份恢复”。
2. 持久化失败、恢复项、完整性问题应能导出给开发者分析。

### 5.11 工程健康、质量基线与发布准备

当前已有：

1. 完整 build 当前可通过。
2. `Quality Smoke` 当前可通过。
3. 项目已具备基础测试矩阵与 baseline 脚本。

代表性证据：

- `scripts/run_quality_smoke.sh`
- `docs/quality/test-matrix-2026-03-11.md`
- `docs/quality/performance-baseline-2026-03-11.md`

缺失项：

1. P0：缺少正式 release 发布检查单。
   当前有开发态 build 和 focused smoke，但还没有一份正式回答“上线前必须验证哪些项”的发布清单。
2. P0：缺少 release 交付流程文档。
   包括 Archive、签名、沙箱策略、分发渠道、是否 notarize、如何验收 release 包。
3. P1：VS Code Problems 与实际 build 成功之间存在工程一致性问题。
   需要在发版前澄清并清理，否则后续维护会持续制造误导。
4. P1：缺少面向真实用户场景的端到端回归用例清单。
   当前 smoke 更偏 focused gate，还需要补一份“首版用户旅程回归表”。

上线要求：

1. 必须新增一份 release checklist。
2. 明确 debug / release 配置差异、签名与分发方式。
3. 补一组覆盖真实首版旅程的回归场景。

## 6. 首版上线前建议补齐的需求清单

### 6.1 P0 清单

1. 首启引导与首轮配置闭环。
2. 主界面空态中的“去设置 / 选目录 / 示例任务”快捷入口。
4. Release checklist 与正式发布流程文档。
5. 设置页连接测试与最低可用配置状态提示。

### 6.2 P1 清单

1. 会话重命名。
2. 输入草稿保存。
3. 文件树新建文件 / 文件夹 / 删除 / 重命名。
4. 文件树搜索。
7. 技能详情预览与安装路径引导。
8. Memory 生命周期说明与基础清理入口。
9. Workflow 停止 / 恢复查看 / 使用引导。


### 6.3 P2 清单

1. 快捷键帮助与交互可发现性增强。
2. 最近文件 / 固定文件 / 快速跳转。
3. 技能搜索与分类。
4. Memory 更强的可解释与治理面板。
5. Git 的 stash / discard / conflict resolution 增强。

## 7. 建议的首版验收标准

首版是否可上线，建议至少满足以下标准：

1. 新用户首次打开应用后，5 分钟内可完成 API Key 配置并成功发出第一条消息。
2. 用户可在应用内选择工作目录、打开文件、编辑并保存文件。
3. 用户可在应用内查看 Git diff，并完成至少一次最小提交闭环，或者明确知道为何此能力暂不支持。
4. 当工具 / 配置不可用时，用户能在 UI 中直接知道原因和下一步操作。
5. 用户可导出并恢复备份，或至少有明确的恢复入口与文档。
6. 完整 build、质量冒烟、首版用户旅程回归全部通过。
7. 有正式的 release 检查单和发布说明，而不只是开发态构建说明。

## 8. 推荐的执行顺序

建议按以下顺序推进：

1. 先补“首启可用性”和“发布检查单”。
2. 再补“文件 / Git / 备份恢复”三类基础操作闭环。
3. 再补“技能 / Memory / Workflow”的说明性和管理性入口。
4. 最后再做 P2 级体验增强。

这样做的原因很简单：当前 agentGui 最大的问题不是“能力不够多”，而是“能力很多，但首版用户不一定走得到、看得懂、用得稳”。首版上线前，优先级应从继续加能力，切换为补闭环、补引导、补恢复、补发布约束。