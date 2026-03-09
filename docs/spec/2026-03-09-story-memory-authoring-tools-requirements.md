# story memory 录入工具补齐需求说明

日期：2026-03-09

## 1. 背景

当前项目已经具备较完整的故事记忆数据模型，用于承载角色、章节、场景、世界规则、地点、时间线、伏笔、风格和连续性问题等信息，并且这些数据已经接入 prompt 组装和项目浏览 UI。

但从当前工具定义与分发实现看，Agent 可直接写入的 story-memory 能力仍然偏少，主要集中在：

- 创建项目
- 绑定项目
- 创建或更新角色
- 追加时间线事件
- 查询部分记忆
- 连续性检查并自动写入问题

这意味着“数据模型已存在、展示已存在、检索已部分存在，但录入工具不完整”。对于长篇小说、多章节连续创作和世界观维护场景，这会导致 story memory 无法成为真正可操作的 canon 系统。

## 2. 基于当前代码的结论

### 2.1 已存在的数据模型

当前 SwiftData 模型已经覆盖以下实体：

- `WritingProject`
- `StoryCharacterProfile`
- `StoryChapterRecord`
- `StorySceneRecord`
- `StoryTimelineEvent`
- `StoryForeshadowItem`
- `StoryWorldRule`
- `StoryLocationProfile`
- `StoryStyleProfile`
- `StoryContinuityIssue`

说明：数据层并不缺章节、伏笔、世界观、地点、风格等对象。

### 2.2 已存在的 story-memory 工具

当前 `ClaudeService+ToolBuilder.swift` 中注册的显式 story-memory 工具只有 6 个：

- `story_memory_create_project`
- `story_memory_attach_project`
- `story_memory_upsert_character`
- `story_memory_append_event`
- `story_memory_query`
- `story_memory_verify_continuity`

其中真正具备“录入/更新”能力的只有：

- 项目创建
- 角色 upsert
- 时间线事件追加
- 连续性问题自动写入

### 2.3 当前缺失的录入能力

当前没有显式工具支持 Agent 直接录入或更新以下对象：

- 章节 `StoryChapterRecord`
- 场景 `StorySceneRecord`
- 伏笔 `StoryForeshadowItem`
- 世界规则 `StoryWorldRule`
- 地点档案 `StoryLocationProfile`
- 风格档案 `StoryStyleProfile`
- 连续性问题的解决状态

### 2.4 当前查询能力也不完整

`story_memory_query` 当前只支持：

- `characters`
- `events`
- `foreshadows`

未覆盖：

- `chapters`
- `scenes`
- `world_rules`
- `locations`
- `style`
- `continuity_issues`

这意味着即使某些数据未来被写入，Agent 也无法通过统一查询接口稳定检索。

### 2.5 UI 现状

当前项目详情页重点在浏览和绑定，不是完整编辑器。它能展示章节数、伏笔数、连续性问题、角色列表、章节列表、时间线等，但不提供完整的结构化录入入口。

因此，用户提出的“章节、伏笔、世界观等似乎没有工具进行记录”这一判断基本成立。

## 3. 问题定义

### 3.1 核心问题

story memory 当前更像“部分可写、部分只读”的半成品：

- prompt 组装依赖世界规则、伏笔、风格、上一场景等信息
- 但 Agent 缺少把这些信息结构化写入系统的工具
- 导致用户只能依赖普通聊天文本描述，无法把关键 canon 沉淀为长期可检索的项目记忆

### 3.2 直接影响

- 章节结构无法沉淀，上一场景衔接能力会逐渐失真
- 伏笔只能被动查询，无法稳定创建、更新、回收
- 世界规则和地点设定无法结构化沉淀，影响后续一致性检查
- 风格约束无法长期维护，写作风格提示会不稳定
- 连续性问题只能新增，无法关闭或标记已处理

## 4. 目标

补齐一组面向创作记忆的结构化录入工具，使 Agent 能够像维护角色和事件一样，维护完整的小说 canon。

目标效果：

- 用户可以要求 Agent 记录章节、场景、伏笔、世界规则、地点和风格约束
- Agent 写入后，数据进入 SwiftData，并可被后续 prompt 组装与查询复用
- 连续性问题形成“发现 -> 跟踪 -> 解决”的闭环

## 5. 需求范围

### 5.1 本期范围

本期聚焦 tool-first 能力补齐，不要求先做完整 GUI 编辑器。

本期必须覆盖：

- 新增 story-memory 录入工具
- 扩展查询工具的查询面
- 补齐 Service 层写入逻辑
- 保证 prompt assembler 能消费新写入数据
- 补齐基础测试与使用文档

### 5.2 非本期范围

本期不要求：

- 完整的富文本大纲编辑器
- 自动章节拆分工作流
- 风格学习模型化训练
- retcon 历史版本管理
- 独立的复杂 story-memory 专用工作台

## 6. 功能需求

### 6.1 新增章节录入工具

新增：`story_memory_upsert_chapter`

用途：创建或更新章节记录。

建议输入字段：

- `project_id` 可选
- `chapter_number` 必填
- `title` 必填
- `outline` 可选
- `summary` 可选
- `tone_directive` 可选
- `is_locked` 可选

行为要求：

- 若项目中已存在同章号章节，则更新
- 若不存在，则创建
- 返回项目名、章节号、标题、更新字段摘要

### 6.2 新增场景录入工具

新增：`story_memory_upsert_scene`

用途：创建或更新章节下的场景记录。

建议输入字段：

- `project_id` 可选
- `chapter_number` 必填
- `scene_index` 必填
- `title` 必填
- `content` 可选
- `pov_character_name` 可选
- `location_name` 可选
- `character_names` 可选
- `summary` 可选
- `previous_scene_id` 可选
- `timeline_event_id` 可选

行为要求：

- 若章节不存在，可配置为自动创建空章节骨架，或返回明确错误
- 同章同场次视为同一场景记录
- 支持在仅更新摘要或角色名单时保留原内容

### 6.3 新增世界规则录入工具

新增：`story_memory_upsert_world_rule`

用途：创建或更新世界规则、制度规则、能力规则、历史设定等。

建议输入字段：

- `project_id` 可选
- `title` 必填
- `category` 可选
- `detail` 可选
- `scope` 可选
- `exceptions` 可选
- `established_in_chapter` 可选
- `related_entities` 可选
- `mutable_policy` 可选

行为要求：

- 以 `title` 作为默认幂等键
- 允许更新规则说明和例外项
- 当规则被标记为不可变时，应在连续性检查中作为强约束

### 6.4 新增地点录入工具

新增：`story_memory_upsert_location`

用途：维护地点设定、地理特征、常驻角色与关联规则。

建议输入字段：

- `project_id` 可选
- `name` 必填
- `summary` 可选
- `traits` 可选
- `related_rules` 可选
- `occupant_names` 可选

行为要求：

- 以地点名作为默认幂等键
- 能支持“更新地点状态”而不是每次重复创建

### 6.5 新增伏笔录入与状态更新工具

新增：`story_memory_upsert_foreshadow`

用途：创建或更新伏笔。

建议输入字段：

- `project_id` 可选
- `tag` 必填
- `introduced_in_chapter` 可选
- `detail` 可选
- `related_event_ids` 可选
- `status` 可选
- `resolved_in_chapter` 可选

行为要求：

- 以 `tag` 作为默认幂等键
- 支持从 `open` 更新为 `planned`、`payoff`、`resolved`
- 当设置 `resolved_in_chapter` 时，应自动联动状态检查

可选拆分工具：

- `story_memory_resolve_foreshadow`

用于高频的“伏笔回收”动作，降低模型误用概率。

### 6.6 新增风格档案录入工具

新增：`story_memory_upsert_style_profile`

用途：维护作品级风格偏好。

建议输入字段：

- `project_id` 可选
- `author_preferences` 可选
- `narrative_voice` 可选
- `sentence_length_mean` 可选
- `dialogue_ratio` 可选
- `imagery_density` 可选
- `sample_passages` 可选
- `anti_patterns` 可选

行为要求：

- 每个项目只允许一个 style profile
- 未提供字段时保留旧值
- 更新后可直接被 prompt assembler 的风格片段消费

### 6.7 连续性问题闭环管理

新增：`story_memory_update_continuity_issue`

用途：对 `story_memory_verify_continuity` 自动发现的问题进行状态管理。

建议输入字段：

- `project_id` 可选
- `issue_id` 或组合定位键
- `resolution_status` 必填
- `resolution_note` 可选

行为要求：

- 支持 `open`、`accepted`、`resolved`、`wont_fix`
- 不要求删除历史问题记录
- 项目展示层默认突出未解决问题

### 6.8 扩展统一查询接口

扩展：`story_memory_query`

新增支持的 `query_kind`：

- `chapters`
- `scenes`
- `world_rules`
- `locations`
- `style`
- `continuity_issues`

要求：

- 保持现有 `characters | events | foreshadows` 不变
- 不同查询类型返回统一、稳定、可读的结构化文本
- 查询结果中必须说明 project scope 与筛选条件

## 7. 数据与服务层要求

### 7.1 StoryMemoryService 扩展

需要在 `StoryMemoryService` 中新增与工具对应的 upsert/update 方法，至少包括：

- `upsertChapter`
- `upsertScene`
- `upsertWorldRule`
- `upsertLocation`
- `upsertForeshadow`
- `upsertStyleProfile`
- `updateContinuityIssue`

### 7.2 幂等与唯一性策略

建议默认唯一键：

- 角色：`name`
- 章节：`chapter_number`
- 场景：`chapter_number + scene_index`
- 世界规则：`title`
- 地点：`name`
- 伏笔：`tag`
- 风格：每项目单例

要求：

- 相同对象重复记录时应更新而不是盲目追加
- 返回结果必须提示是“created”还是“updated”

### 7.3 与 prompt assembler 的一致性

新增录入工具写入的数据，必须与以下消费逻辑保持一致：

- 上一场景衔接依赖章节与场景记录
- 世界规则片段依赖 `worldRules`
- 未解决伏笔片段依赖 `foreshadowItems`
- 风格指令依赖 `styleProfile`

## 8. 交互与错误处理要求

### 8.1 项目上下文

所有新工具必须遵循现有规则：

- 优先使用显式 `project_id`
- 未提供时回退到当前会话绑定项目
- 二者都缺失时返回明确错误

### 8.2 输入校验

要求：

- 缺少关键定位字段时返回可读错误
- 章号、场次等必须为正整数或约定的非负整数
- 空标题、空名称、空 tag 不允许写入

### 8.3 输出格式

所有录入工具统一返回：

- 操作对象
- 所属项目
- created / updated 状态
- 主键或定位信息
- 实际变更字段摘要

## 9. 测试要求

至少补充以下测试：

- 章节 upsert：首次创建、重复更新
- 场景 upsert：章节存在与不存在两种路径
- 世界规则 upsert：规则更新后能被 prompt assembler 读取
- 伏笔 upsert 与 resolve：未解决列表能正确变化
- 风格 profile 更新：prompt assembler 输出随之变化
- continuity issue 更新：项目展示层统计正确
- query 扩展：各新增 query_kind 返回符合预期

## 10. 文档要求

需要同步更新：

- story memory 使用说明
- 工具清单说明
- 若 `story_memory_query` 支持范围改变，必须修正文档与实现不一致的问题

## 11. 验收标准

满足以下条件视为本需求完成：

1. Agent 可以通过显式工具记录章节、场景、伏笔、世界规则、地点、风格。
2. Agent 可以更新伏笔和连续性问题的状态，而不是只能新增。
3. `story_memory_query` 可以查询新增对象类型。
4. 新写入数据能被现有 story-memory prompt 组装逻辑消费。
5. 项目详情页中的统计和列表不会因新工具接入而失真。
6. 使用说明文档与实际工具能力保持一致。

## 12. 优先级建议

### P0

- `story_memory_upsert_chapter`
- `story_memory_upsert_scene`
- `story_memory_upsert_world_rule`
- `story_memory_upsert_foreshadow`
- `story_memory_upsert_style_profile`
- `story_memory_query` 扩展

### P1

- `story_memory_upsert_location`
- `story_memory_update_continuity_issue`
- 伏笔专用 resolve 工具

### P2

- 更完整的创作记忆编辑 UI
- 自动抽取与人工修订混合工作流
- retcon / 版本追踪

## 13. 结论

当前代码里，章节、伏笔、世界观、地点、风格等对象并不是没有模型，而是没有完整的 Agent 录入工具链。这是一个真实存在的产品缺口，不是用户错觉。

因此，下一步应优先补齐 story-memory 的结构化 authoring tools，使 story memory 从“只支持角色与事件的半成品”升级为“完整可维护的小说 canon 系统”。