# 小说场景下的通用记忆系统设计报告

日期：2026-03-09

对应实施方案：`docs/plans/2026-03-09-novel-memory-runtime.md`

## 1. 背景与目标

当前 agentGui 已经具备三类记忆雏形：

- 窗口内短期记忆：最近若干轮消息原文
- 上下文压缩记忆：`ContextMemory`
- 会话级持久记忆：`TaskMemory`

这套结构对 coding agent 已经有价值，但如果要扩展到更长周期、更高一致性要求的创作型任务，例如长篇小说写作，还存在几个明显不足：

- 持久化结构仍偏“任务执行日志”，不适合表达角色、设定、情节、风格这些长期对象
- 检索维度还不够明确，更多依赖整段摘要，而不是按角色、章节、地点、时间线、主题进行召回
- 写入策略不够严格，尚未区分“可演化草稿”和“应尽量稳定的事实”
- 缺少一致性校验层，无法系统性发现角色失真、设定冲突、时间线断裂、风格漂移

本报告的目标，是设计一套更强大、通用、可扩展的记忆系统架构，使其既能服务小说写作，也能反向统一 agentGui 中更广义的长任务记忆能力。

设计原则如下：

- 分层：不同记忆层承担不同成本、时效和可信度
- 结构化：尽量避免把关键状态只存成大段文本
- 可检索：所有高价值记忆都应支持按对象、标签、时间、关系查询
- 可演化：允许草稿变化，但要保留版本和审计轨迹
- 可验证：在生成前、生成中、生成后，都能做一致性检查

## 2. 成熟实践综述

### 2.1 Generative Agents 的启发

Generative Agents 的核心不是“摘要更多文本”，而是把记忆拆成三个动作：

- observation：记录经历
- reflection：从多条经历中提炼高层结论
- planning：基于当前目标动态取回相关记忆

这个思路对小说系统很有价值，因为小说创作同样需要：

- 保存细粒度事件
- 把事件提升为更稳定的人物关系、主题变化、剧情结论
- 在写当前场景时只取回真正相关的少量上下文

因此，小说记忆系统不应只有“总结”，还应具备：

- 事件流
- 反思层
- 面向当前写作任务的动态检索层

### 2.2 MemGPT 的启发

MemGPT 的关键贡献，是把 LLM 的上下文窗口看成“主存”，把外部持久层看成“磁盘”，通过分层管理创造“虚拟上下文”。

对小说场景而言，这意味着：

- 当前窗口里不应该塞完整角色档案和全部历史剧情
- 只有“当前章节真正需要的记忆切片”才进入 prompt
- 其余内容留在外部存储，通过检索按需换入

这比把所有历史持续拼接到对话里要可靠得多，也更接近生产可用系统。

### 2.3 生产型 Agent / RAG 系统的启发

LangGraph、LlamaIndex、各类生产型 agent memory 的共性经验基本一致：

- 把 memory 分成短期、长期、语义、情节化几类
- 把写入和检索解耦，而不是只做“追加文本”
- 对长期记忆实行明确的 write policy
- 对高价值事实实行半结构化或结构化存储
- 用标签检索、精确查询、时间查询做主召回；向量相似度做辅召回

这个结论很重要：

对小说系统来说，不能只依赖 embedding 相似搜索。大量关键信息更适合结构化检索，例如：

- 第 12 章出现过哪些人物
- 某个角色最后一次出现在什么地点
- 哪些伏笔尚未回收
- 某条魔法规则在第几章首次建立

## 3. 推荐的总体验证架构

建议把记忆系统分为五层，而不是只保留当前的三层：

### 3.1 L0：In-Context Working Memory

这是最热层，直接进入模型上下文。适合放：

- 当前章节草稿
- 上一章摘要
- 当前场景人物
- 当前 scene 的明确目标
- 当前场景的约束清单

它的特点是：

- 容量最小
- 时效性最强
- 每轮都可能变化
- 由调度器动态构造，不直接持久化为单一文本真相源

对小说场景，建议 L0 的固定模板为：

1. 当前写作目标
2. 当前场景摘要
3. 上一场景衔接点
4. 活跃角色卡片
5. 必须遵守的世界规则切片
6. 当前章节风格指令

### 3.2 L1：Session / Chapter Working Memory

这是当前章节或当前写作会话的结构化工作记忆，用于承接上下文压缩结果。适合放：

- 本章已完成场景
- 本章待写场景
- 本章角色出场记录
- 本章主题推进状态
- 本章风格偏移提醒
- 本章未解决连续性问题

这一层可以视为小说场景下的 `ContextMemory` 升级版。它不是长期事实库，而是当前章节的“操作态”。

### 3.3 L2：Episodic Memory Stream

这是事件流层，直接借鉴 Generative Agents 的 Memory Stream 思路。每条记录都是一条时间有序的经历或剧情单元。

建议事件条目至少包含：

- 章节
- 场景
- 事件描述
- 参与人物
- 地点
- 时间标记
- 事件类型
- 伏笔标记
- 是否已解决
- 影响对象
- 来源文本片段或场景 ID

这一层非常关键，因为它是：

- 剧情回溯的主数据源
- 角色经历提炼的原材料
- 反思层生成“高层结论”的输入
- 连续性校验的事实依据

### 3.4 L3：Semantic Memory

这是稳定知识层，适合保存相对持久、需要反复复用的事实：

- 角色记忆
- 世界观记忆
- 风格记忆
- 主题与母题记忆
- 关系网络记忆

这一层不能只是 Markdown 文本拼盘，建议采用“文档 + 结构化字段”的混合形态。

### 3.5 L4：Archive / Version Store

这是归档层，用于保留：

- 历史章节版本
- 废弃分支剧情
- 被推翻的人设草稿
- 被 retcon 的旧设定
- 风格样本快照

这层不应直接注入模型，但对审计、回滚、风格学习和长线创作非常重要。

## 4. 小说场景下的领域记忆模型

### 4.1 In-Context 短期记忆

你给出的例子是合理的，但建议再往前走一步，把它从“几个文本块”升级为“可编排的 prompt slice”：

- 当前章节草稿
- 上一章摘要
- 当前场景人物
- 当前场景地点
- 当前场景的冲突目标
- 本场景必须回收或铺设的伏笔
- 当前风格指令

其中：

- “上一章摘要”不要是单一摘要，最好拆成剧情、人物状态、未解问题三部分
- “当前场景人物”不要只给名字，应该给每个角色一个简卡：目标、情绪、关系、语言特征
- “当前章节草稿”不应无限增长，而应只放当前 scene 和必要衔接上下文

### 4.2 角色记忆

建议每个角色独立文档，同时维护一份结构化 profile。推荐字段：

- 基本信息：姓名、年龄、身份、外貌、背景
- 稳定特征：价值观、动机、恐惧、秘密
- 行为特征：常见决策模式、禁忌、情绪触发器
- 语言风格：说话节奏、口头禅、句式习惯、语气偏好
- 关系网络：和其他角色的关系、关系变化历史
- 角色弧线：起点、关键转折、当前阶段、预期终点
- 连续性状态：最后出现章节、最后已知地点、当前伤势/状态/立场

建议实现形态：

- 文档层：便于编辑和阅读
- 结构化层：便于查询和校验

仅有文档层会导致召回模糊；仅有结构化层会导致创作弹性不足。两者应共存。

### 4.3 情节记忆

情节记忆应采用时序事件流，而不是只存章节摘要。建议的最小事件 schema：

```json
{
  "event_id": "evt_001",
  "chapter": 12,
  "scene": 3,
  "title": "林澈发现塔楼密室",
  "summary": "主角在追踪失踪线索时进入塔楼密室，发现王室档案残页。",
  "participants": ["林澈"],
  "location": "北塔密室",
  "time_marker": "深夜",
  "event_type": "discovery",
  "foreshadow_tags": ["王室血统", "旧王朝档案"],
  "resolved": false,
  "consequences": ["evt_014", "evt_019"]
}
```

这层要支持的核心操作包括：

- 追加新事件
- 将事件标记为已解决
- 关联前因后果
- 标记 retcon / superseded
- 按角色、地点、章节、伏笔标签查询

### 4.4 世界观记忆

世界观记忆建议至少拆成四类：

- 地理
- 历史
- 规则系统
- 势力与组织

其中“规则系统”尤其重要。无论是魔法、科技、政治制度，还是社会礼法，都应该尽量被建模成“规则项”而不是长文说明。每条规则建议包含：

- 标题
- 描述
- 生效范围
- 例外条件
- 首次建立章节
- 相关地点/势力/人物
- 是否允许覆盖

经验上，世界规则一旦写进正文，就不应该被静默覆盖，只能：

- 补充解释
- 显式修订
- 标记为 retcon

### 4.5 风格记忆

风格记忆是最容易被低估的一层。单纯保存“作者喜欢什么风格”远远不够，建议拆成三部分：

- 显式偏好：例如第三人称限知、偏冷峻、少形容词、对白克制
- 统计画像：平均句长、对话占比、比喻密度、词汇复杂度
- 样本文本：若干段代表性文本，用于 few-shot 风格对齐

风格记忆不要和剧情事实混存。它是生成策略，不是世界事实。

## 5. 检索架构建议

一个成熟的小说记忆系统，检索不应只有一种方式。建议采用四路召回：

### 5.1 精确检索

适用于：

- 角色名
- 章节号
- 地点名
- 规则 ID
- 伏笔标签

这是成本最低、准确度最高的检索方式，应当优先。

### 5.2 结构化过滤检索

适用于组合条件，例如：

- 第 8 到 12 章中，所有同时涉及“林澈”和“顾沉”的事件
- 所有未解决的伏笔
- 所有发生在“王都”且涉及“禁术”的场景

这是小说系统里最有价值的一类检索，不应被向量搜索替代。

### 5.3 时间线检索

适用于：

- 某角色最后一次出现在哪里
- 某条关系是什么时候恶化的
- 某件物品是何时第一次出现的

这要求所有事件和场景都带有可排序时间轴。

### 5.4 相似度检索

适用于：

- 找相似语气的样本文本
- 找节奏相近的历史场景
- 找语义相关但标签不完全一致的记忆

它应该是辅助检索，不应成为主检索。小说一致性问题大多是结构性问题，不是语义相似问题。

## 6. 写入与更新策略

记忆系统稳定性的关键不在“能不能写”，而在“什么时候写、写到哪一层、是否允许覆盖”。建议采用以下 policy：

### 6.1 草稿内容

- 允许频繁更新
- 必须保留版本
- 支持用户锁定章节
- 不直接覆盖归档版本

### 6.2 事件流

- 原则上只追加
- 状态允许从“未解决”更新为“已解决”
- 若需推翻，应标记 `superseded` 或 `retcon`

### 6.3 角色与世界规则

- 默认视为半稳定事实
- 用户直接编辑时可更新
- 模型自动写入时必须经过冲突检查
- 若与既有事实矛盾，应先生成冲突而不是直接覆盖

### 6.4 风格画像

- 允许逐步学习和累计
- 显式偏好由用户或设定面板维护
- 统计画像可自动更新
- 样本文本要支持人工选定为“基准样本”

## 7. 一致性与质量校验层

如果没有校验层，记忆再多也只是“更快地犯错”。建议增加四类校验：

### 7.1 角色连续性校验

检查：

- 外貌是否突然变化
- 说话风格是否明显漂移
- 情绪和立场变化是否有事件支撑
- 人物是否出现在不合理地点

### 7.2 时间线校验

检查：

- 事件顺序是否矛盾
- 同一时间角色是否出现在两个地点
- 伏笔是否已回收却再次当成未揭示信息使用

### 7.3 世界规则校验

检查：

- 新写内容是否违反魔法/科技/制度规则
- 是否引入未声明例外
- 是否出现静默 retcon

### 7.4 风格漂移校验

检查：

- 当前 scene 与本章风格 baseline 的距离
- 高频短语过度重复
- 对白、叙述、描写比例是否偏离既定风格

建议把这些校验结果作为单独的 memory/diagnostics channel，而不是混在正文摘要里。

## 8. 适合 agentGui 的实现方案

结合当前项目，我建议不要推翻现有 `ContextMemory` 和 `TaskMemory`，而是升级为更完整的层次：

### 8.1 保留现有层

- `ContextMemory` 继续承担 L1：当前会话/章节工作记忆
- `TaskMemory` 继续承担“任务级 durable state”，但需要扩 schema
- `memory.md` 继续承担全局长期偏好，但不再试图承载全部领域记忆

### 8.2 新增领域记忆层

建议引入项目级 `ProjectMemory`，按 novel project 进行组织，底层使用 SwiftData，必要时辅以 JSON 导出。

推荐实体：

- `WritingProject`
- `CharacterProfile`
- `WorldRule`
- `LocationProfile`
- `TimelineEvent`
- `ChapterRecord`
- `SceneRecord`
- `StyleProfile`
- `ForeshadowItem`
- `ContinuityIssue`
- `MemorySnapshot`

### 8.3 检索服务层

新增统一的 `MemoryRetrievalService`，负责：

- 根据当前写作上下文拼装 L0 prompt slice
- 查询活跃角色卡片
- 查询相关世界规则
- 查询最近关联事件
- 查询未解决伏笔
- 查询风格样本

这个服务应该输出“结构化切片”，由 ClaudeService 再决定怎样注入 prompt。

### 8.4 反思与压缩层

当前 `ContextCompression` 已经有基础。下一步建议增加两种后台提炼流程：

- `EpisodicExtractionJob`：从新生成的 scene 中提取事件流条目
- `SemanticReflectionJob`：从多条事件流中提炼角色关系变化、主题推进、高层设定结论

这一步对应 Generative Agents 的 reflection。

### 8.5 工具层

如果未来让 agent 直接写小说，建议提供专门的 memory tools，而不是只靠通用 `memory_write`：

- `upsert_character_profile`
- `append_timeline_event`
- `resolve_foreshadow`
- `query_story_memory`
- `verify_story_continuity`
- `save_scene_version`
- `retrieve_style_samples`

只有这样，模型才会把记忆当“系统能力”而不是“往文件里写一段字”。

### 8.6 当前落地映射（2026-03-09）

截至当前版本，agentGui 已经按这个方向落地出第一批可用实现，但做法更收敛，也更贴近现有代码边界。

已落地的运行时边界如下：

- 配置入口：`AppSettings` 新增 `enableStoryMemory`、`storyMemoryAutoExtract`、`storyMemoryPromptBudget`、`storyMemoryProjectMode`
- 会话桥接：`Session.activeWritingProjectId` 负责把当前聊天会话绑定到某个 `WritingProject`
- SwiftData 根实体：`WritingProject` 作为聚合根，向下组织角色、规则、地点、风格、章节、场景、时间线、伏笔和连续性问题
- 服务层：`StoryMemoryService`、`StoryMemoryRetrievalService`、`StoryMemoryPromptAssembler`、`StoryContinuityService`、`StoryMemoryExtractionService`
- Prompt 注入点：在 `ACPClientService` 与 `ClaudeService+AgenticLoop` 中按需拼装项目记忆切片，仅在已启用且会话已绑定项目时生效
- 工具层：当前实际暴露的工具名为 `story_memory_create_project`、`story_memory_attach_project`、`story_memory_upsert_character`、`story_memory_upsert_chapter`、`story_memory_upsert_scene`、`story_memory_upsert_world_rule`、`story_memory_upsert_location`、`story_memory_upsert_foreshadow`、`story_memory_upsert_style_profile`、`story_memory_update_continuity_issue`、`story_memory_append_event`、`story_memory_query`、`story_memory_verify_continuity`
- UI 入口：设置页的「创作记忆」区块、聊天工具栏的项目入口，以及项目列表/项目详情/时间线视图

当前实现刻意保留了两个约束：

- 不把小说 canon 写入 `memory.md`，避免与全局用户偏好、通用长期记忆混杂
- 不在第一版就做全量富文本故事编辑器，而是优先把“可绑定、可检索、可校验”的底座打通

新增 authoring 工具补齐后，当前运行时已经不再局限于“角色 + 事件”这两个写入口，而是可以直接维护：

- 章节与场景结构
- 世界规则与地点档案
- 伏笔创建、推进与回收状态
- 项目级风格约束
- 连续性问题的跟踪状态

与此同时，`story_memory_query` 也从早期的 `characters | events | foreshadows` 扩展到了章节、场景、世界规则、地点、风格档案和连续性问题，使工具写入的数据可以通过统一接口重新被 Agent 检索。

还没有完成的部分主要包括：

- 更丰富的角色/项目编辑 UI
- 自动抽取剧情事件的完整后台流程
- 更深入的风格样本学习与版本归档界面

## 9. 推荐数据模型

建议的最小结构如下：

### 9.1 角色

- `id`
- `name`
- `summary`
- `traits`
- `goals`
- `fears`
- `speech_style`
- `relationships`
- `arc_stage`
- `last_seen_chapter`
- `last_known_location`
- `status_flags`

### 9.2 事件

- `id`
- `chapter`
- `scene`
- `title`
- `summary`
- `participants`
- `location`
- `time_marker`
- `event_type`
- `foreshadow_tags`
- `resolved`
- `superseded_by`
- `source_scene_id`

### 9.3 世界规则

- `id`
- `category`
- `title`
- `description`
- `scope`
- `exceptions`
- `established_in_chapter`
- `related_entities`
- `mutable_policy`

### 9.4 风格

- `id`
- `author_preferences`
- `narrative_voice`
- `sentence_length_mean`
- `dialogue_ratio`
- `imagery_density`
- `sample_passages`
- `anti_patterns`

### 9.5 伏笔

- `id`
- `tag`
- `introduced_in`
- `description`
- `related_events`
- `status`
- `resolved_in`

## 10. Prompt 组装策略

建议不要把所有记忆平铺注入，而是按“当前任务”拼装：

### 10.1 写新 scene 时

注入：

- 当前 scene 目标
- 上一 scene 摘要
- 当前活跃角色卡片
- 相关地点/世界规则
- 最近 3 到 8 条强相关事件
- 本章风格指令
- 未解决伏笔列表

### 10.2 做一致性校验时

注入：

- 当前草稿
- 涉及角色 profile
- 涉及地点规则
- 相关时间线切片
- 历史冲突记录

### 10.3 做角色润色时

注入：

- 角色 profile
- 该角色代表性对白样本
- 最近涉及该角色的事件
- 当前要润色的段落

这样做的好处是，模型看到的是“与当前任务强相关的高密度上下文”，而不是一份越来越长的总记忆。

## 11. 分阶段落地路线

### Phase 1：从现有系统平滑升级

- 扩展 `TaskMemory` schema，支持 story-specific 字段
- 把 `ContextMemory` 从通用任务字段扩展成可插拔 slice 模型
- 新增 `TimelineEvent` 与 `CharacterProfile` 的 SwiftData 模型
- 增加基础查询接口：按角色、章节、地点查询

这是成本最低、收益最高的一步。

### Phase 2：建立事件流与检索层

- 每次 scene 保存后自动抽取事件
- 支持未解决伏笔管理
- 支持世界规则查询和冲突提示
- 支持按当前 scene 自动拼装 prompt

这一阶段完成后，系统会从“记住一些东西”升级为“能在写作时拿回正确的东西”。

### Phase 3：建立反思与校验层

- 自动提炼角色弧线阶段
- 自动提炼主题推进
- 连续性检查器
- 风格漂移分析器
- retcon 管理

这一阶段才是真正把系统做成“长期创作辅助器”。

### Phase 4：引入更通用的 Memory Runtime

- 统一 memory scopes
- 统一 retrieval API
- 统一 write policy
- 支持不同 agent / subagent 的独立 memory slice

完成这一步后，这套系统就不只是小说记忆，而是 agentGui 的通用记忆底座。

## 12. 结论

对于小说写作，一个真正强大的记忆系统不应只是：

- “把前文总结一下”
- “给每个角色写个文档”
- “保存几段风格样本”

而应是一套分层、结构化、可检索、可验证、可审计的 memory runtime。

推荐的最终方向是：

- 用 L0/L1 解决当前写作上下文容量问题
- 用事件流承接长期剧情记忆
- 用语义记忆承接角色、世界、风格这些稳定对象
- 用检索服务把相关切片动态装配进 prompt
- 用校验层约束连续性、设定一致性和风格稳定性

如果从 agentGui 当前基础继续演进，这条路线是连续的，不需要推翻现有 `ContextMemory` / `TaskMemory`，但需要把它们从“摘要系统”升级为“记忆运行时”的一部分。

从成熟实践看，最值得优先落地的不是更大的摘要，而是三件事：

- 事件流
- 结构化检索
- 一致性校验

这三项一旦到位，小说场景下的记忆系统才会真正进入可用阶段。

对 agentGui 当前代码来说，这三项已经有了第一版闭环：项目级结构化模型已经存在，检索与 prompt 组装已经接入主循环，连续性校验和显式工具 API 也已打通。下一步工作的重点不再是“是否要做这套系统”，而是继续增强抽取质量、编辑体验和版本治理能力。