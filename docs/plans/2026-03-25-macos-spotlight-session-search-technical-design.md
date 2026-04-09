# macOS 会话 Spotlight 接入技术设计文档

> **文档状态:** 研究草稿 · 2026-03-25  
> **作者:** 基于 Apple 官方文档与 agentGui 现有架构的调研分析  
> **目标平台:** macOS 14+ 优先，兼容 Core Spotlight 可用版本  
> **关联代码:** `agentGui/Models/Session.swift`, `agentGui/Models/Message.swift`, `agentGui/Utilities/WorkspaceState.swift`, `agentGui/agentGuiApp.swift`, `agentGui/AppCommands/Indexes/RecentSessionProvider.swift`

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [Apple 官方文档调研结论](#2-apple-官方文档调研结论)
3. [现有代码基线](#3-现有代码基线)
4. [需求定义与非目标](#4-需求定义与非目标)
5. [方案选型](#5-方案选型)
6. [推荐架构设计](#6-推荐架构设计)
7. [索引数据模型设计](#7-索引数据模型设计)
8. [索引同步策略](#8-索引同步策略)
9. [Spotlight 打开会话的激活链路](#9-spotlight-打开会话的激活链路)
10. [隐私与安全设计](#10-隐私与安全设计)
11. [失败恢复与重建机制](#11-失败恢复与重建机制)
12. [测试与验证方案](#12-测试与验证方案)
13. [实施路线图](#13-实施路线图)
14. [风险与权衡](#14-风险与权衡)
15. [附录：Apple 文档清单](#15-附录apple-文档清单)

---

## 1. 背景与目标

agentGui 当前已经有完整的会话持久化模型，`Session` 保存标题、创建/更新时间、来源、工作目录以及消息关联；`Message` 保存文本消息内容和时间戳。应用内部已经有“最近会话”和命令面板检索能力，但这些能力都只存在于 app 内部，尚未接入 macOS 系统级 Spotlight。

本设计的目标是把“当前用户关心的会话数据”接入 macOS Spotlight，使用户可以在系统搜索中直接搜到 agentGui 会话，并在点击结果后恢复到对应会话。

这里的“接入 Spotlight”不只是把一批字符串塞进索引，而是要完整回答以下工程问题：

- 该用哪条 Apple 官方能力链路，`Core Spotlight`、`NSUserActivity`，还是两者结合。
- 索引什么内容，标题、预览、工作目录、消息摘要分别如何映射。
- 会话新增、重命名、删除、消息变化时如何增量更新索引。
- Spotlight 结果被点击后，应用如何精确恢复到 `WorkspaceState.selectedSession`。
- 当索引丢失、损坏或 app 不在前台时，如何重建和恢复。

设计目标是给后续实现提供一条低风险、与现有 SwiftData 架构兼容、可灰度演进的技术路径。

---

## 2. Apple 官方文档调研结论

### 2.1 Core Spotlight 是主方案，不应只依赖 NSUserActivity

Apple 在 `NSUserActivity` 文档中明确说明：如果只是记录“用户刚刚执行的活动”，可以通过 `isEligibleForSearch = true` 让该活动进入 on-device 搜索；但它不适合作为 app 全量数据的通用索引机制。对于要把 app 管理的数据系统化接入 Spotlight，Apple 明确推荐使用 `Core Spotlight`。

这和本需求完全匹配，因为我们要索引的是持久化会话集合，而不是只有“当前正在看的一个会话”。因此：

- **全量会话索引** 使用 `CSSearchableIndex` + `CSSearchableItem`
- **当前前台会话的恢复提示** 可额外使用 `NSUserActivity`

两者职责不同，不能互相替代。

### 2.2 生产环境应使用命名索引，而不是默认索引

Apple 在 `Adding your app’s content to Spotlight indexes` 中建议，生产环境不要依赖 `CSSearchableIndex.default()`，而应使用命名索引。命名索引支持更清晰的生命周期管理；如果未来需要更高数据保护级别，还可使用带 `protectionClass` 的索引构造器。

因此本设计建议建立命名索引：

- 索引名：`agentgui.sessions`
- 域标识：`conversation.session`

后续如果要把“本地会话”和“外部只读投影会话”分层，也可以扩展为多个 domain identifier，而无需推翻整体结构。

### 2.3 索引必须保持实时一致，更新和删除都要显式维护

Apple 官方文档对 `CSSearchableItem` 的要求非常直接：

- 内容创建时立即建索引
- 内容属性变化时重新提交同一 `uniqueIdentifier`
- 内容删除时显式调用 `deleteSearchableItems`

这意味着 Spotlight 集成不能只是“启动时做一次全量导入”。它必须成为会话生命周期的一部分。否则结果会脏、会话打不开、搜索质量下降。

### 2.4 批量重建应使用 beginBatch/endBatch，并保留 client state

Apple 建议在大量数据导入时使用 batch API，原因有二：

- 可以减少崩溃或中断后的恢复成本
- 可以用 client state 记录重建进度

对 agentGui 而言，这直接对应“首次启用 Spotlight”与“索引全量重建”两个场景。增量同步仍然走单项 upsert，但全量重建应走 batch。

### 2.5 系统可能要求重建索引，正式版本应预留 reindex extension

Apple 在 `Regenerating your app’s indexes on demand` 中建议提供 Core Spotlight Delegate extension，用于系统要求重新构建索引时处理 `reindex all` 或 `reindex identifiers` 请求。

这不是 Demo 级别功能，而是正式稳定性的一部分。系统索引可能缺失、用户可能迁移环境、app 可能在更新索引时崩溃。若没有 reindex extension，只能等应用启动后自己修；若有 extension，系统可在 app 不运行时请求重建。

因此本设计将 extension 列为 **Phase 2 稳定性增强项**，不阻塞首期上线，但在技术结构上要预留共享索引构建逻辑。

### 2.6 结果打开链路依赖 user activity 恢复

Apple 为 `CSSearchableItem` 提供了继续活动相关常量，包括：

- `CSSearchableItemActionType`
- `CSSearchableItemActivityIdentifier`

这意味着用户从 Spotlight 点击结果回到 app 时，应用恢复入口拿到的是一个 `NSUserActivity`，其中包含 searchable item 的标识。设计上不能把 Spotlight 打开链路写死在某个 View 里，而应当有一个 app 级恢复协调器来解析 activity、查找 session，并把结果投递到工作台状态。

### 2.7 Apple Intelligence 的摘要/优先级能力暂不作为首期依赖

Apple 现在允许对 message/email/audio transcript 类型的 indexed item 请求摘要和优先级分类，但前提包括：

- `contentType` 需要是 message/email/audio transcript 一类
- 文本长度、时间窗口、作者信息等字段需要满足要求
- 生成结果是异步返回的附加能力

这对未来“会话摘要卡片”很有吸引力，但不适合作为首期 Spotlight 接入的前提条件。首期目标是 **可搜到、可打开、可持续同步**。摘要增强可在后续迭代考虑。

---

## 3. 现有代码基线

### 3.1 数据模型已具备索引基础字段

`Session` 当前已有以下可直接用于 Spotlight 的字段：

- `sessionId`: 稳定唯一标识，适合作为 `CSSearchableItem.uniqueIdentifier`
- `title`: 结果主标题
- `updatedAt`: 排序与时间相关元数据
- `createdAt`: 创建时间
- `sourceDisplayName` / `displaySourceTitle`: 来源说明
- `workingDirectory`: 可作为补充检索词和描述信息
- `lastMessagePreview`: 可作为 Spotlight 描述摘要
- `messageCount`: 可作为扩展属性来源

`Message` 则提供：

- `textContent`: 可拼接为更强的全文摘要来源
- `timestamp`: 可用于推导最新消息时间
- `direction`: 可帮助未来做“用户问题 vs Agent 回复”区分

### 3.2 当前没有任何 Spotlight 集成

仓库中目前没有以下内容：

- `CoreSpotlight` import
- `CSSearchableIndex` / `CSSearchableItem` 使用
- `NSUserActivity` 恢复入口
- `onContinueUserActivity` 或等效 app 级恢复处理

这意味着本次设计需要同时覆盖：索引写入、删除、重建、恢复四条链路。

### 3.3 已有会话选中机制可复用

工作台当前通过 `WorkspaceState.selectedSession` 表示当前活跃会话。命令面板、最近会话切换、侧栏会话列表，最终都收敛到设置这个状态。

因此，Spotlight 恢复的目标不是发明一套新的导航系统，而是统一到：

1. 根据 `sessionId` 查到 `Session`
2. 打开主工作台窗口
3. 把该 `Session` 赋值给 `workspaceState.selectedSession`

这给设计提供了非常清晰的收敛点。

---

## 4. 需求定义与非目标

### 4.1 功能需求

首期范围建议如下：

1. 支持在 macOS Spotlight 中按会话标题搜索 agentGui 会话。
2. 支持按来源名、工作目录片段、最后消息预览中的文本命中会话。
3. Spotlight 结果点击后，agentGui 打开并恢复到对应会话。
4. 会话新增、重命名、删除、消息更新后，索引在可接受延迟内保持一致。
5. 应用支持触发一次全量重建索引。

### 4.2 质量要求

- 索引写入不得阻塞主聊天体验。
- 结果打开失败时必须优雅降级，不能让 app 进入无响应状态。
- 删除会话后 Spotlight 不应长期保留僵尸结果。
- 方案必须兼容现有 SwiftData 主存储，不引入第二套会话事实源。

### 4.3 非目标

首期明确不做：

- 不把每一条消息都作为独立 Spotlight 结果暴露。
- 不做跨设备同步索引。
- 不依赖 Apple Intelligence 摘要或优先级作为核心功能。
- 不把 Spotlight 结果直接定位到消息级滚动锚点。
- 不在首期就引入复杂的多实体 App Intents / AppEntity 搜索体系。

原因很简单：首期要先把“会话级检索与恢复”跑通，避免把消息级全文索引、智能摘要、深层导航耦合进第一个版本。

---

## 5. 方案选型

### 5.1 方案 A：只使用 NSUserActivity

优点：

- 接入成本低
- 与“当前正在浏览的会话”语义天然匹配

缺点：

- 不适合全量持久化会话索引
- 很难保证历史会话完整可搜
- 前台之外的数据覆盖率不足

结论：**不推荐作为主方案**。

### 5.2 方案 B：只使用 Core Spotlight

优点：

- 完整覆盖会话集合
- 官方推荐用于 app 数据索引
- 支持增量维护、删除、批量重建

缺点：

- 恢复链路仍需解析 user activity
- 当前前台会话状态与系统活动之间缺少额外增强

结论：**可行，但前台恢复体验可再加强**。

### 5.3 方案 C：Core Spotlight 作为主索引，NSUserActivity 作为当前会话补充

优点：

- 与 Apple 官方职责划分一致
- 全量会话可搜，当前会话也有系统级上下文活动
- 后续支持 Handoff、Quick Note、快捷能力的扩展空间更好

缺点：

- 需要维护两条相关但不同的链路

结论：**推荐方案**。

---

## 6. 推荐架构设计

### 6.1 核心原则

1. `Session` 仍然是唯一事实源。
2. Spotlight 索引是派生视图，而不是第二存储。
3. 索引同步与 UI 恢复分离，避免 View 层直接操作 Core Spotlight。
4. 打开 Spotlight 结果统一走 app 级协调器，避免多入口分叉。

### 6.2 架构分层

推荐新增以下抽象：

```text
SwiftData Session / Message
          ↓
SessionSpotlightDocumentBuilder
          ↓
SessionSpotlightIndexer
          ↓
CSSearchableIndex(name: "agentgui.sessions")

NSUserActivity 当前会话活动
          ↓
SessionActivityCoordinator

Spotlight / NSUserActivity 恢复事件
          ↓
SessionSpotlightOpenCoordinator
          ↓
WorkspaceState.selectedSession
```

### 6.3 推荐新增组件

#### 1. SessionSpotlightDocumentBuilder

职责：把 `Session` 转为索引文档，不直接依赖具体索引 API。

输出内容包括：

- searchable item identifier
- domain identifier
- `CSSearchableItemAttributeSet`
- 自定义 userInfo 载荷所需字段

这样未来如果引入 AppEntity 或测试替身，不需要重写索引映射逻辑。

#### 2. SessionSpotlightIndexer

职责：封装 Core Spotlight 的实际 upsert、delete、rebuild API。

建议能力：

- `upsert(session:)`
- `upsert(sessions:)`
- `delete(sessionID:)`
- `deleteAllSessions()`
- `rebuildAll(using:)`

该组件内部序列化访问命名索引，遵循 Apple 对“同一个 custom index 不要并发多线程修改”的要求。

#### 3. SessionActivityCoordinator

职责：维护当前前台会话的 `NSUserActivity`。

它只关心“当前正在看的会话”，不关心全量索引。切换 `selectedSession` 时，更新活动标题、标识和关键词，并调用 `becomeCurrent()`。

#### 4. SessionSpotlightOpenCoordinator

职责：接收 app 级恢复事件，解析 `NSUserActivity`，提取 searchable item identifier 或 persistent identifier，查询 SwiftData，最终选中对应会话。

该组件需要与窗口打开逻辑协作，但不应直接耦合到具体某个 View。

---

## 7. 索引数据模型设计

### 7.1 searchable item 标识策略

推荐：

- `uniqueIdentifier = session.sessionId`
- `domainIdentifier = "conversation.session"`

理由：

- `sessionId` 已经是持久层稳定主键
- 删除、更新、恢复路径都能直接复用
- 不需要额外维护 Spotlight 专用主键

如果未来需要索引不同实体类型，可引入前缀，例如 `session:<id>`；但首期直接用 `sessionId` 更简洁。

### 7.2 Attribute Set 字段映射

推荐字段如下：

| Spotlight 字段 | 来源 | 用途 |
| --- | --- | --- |
| `title` | `session.title` | 搜索结果主标题 |
| `displayName` | `session.title` | 结果展示名称 |
| `contentDescription` | `session.lastMessagePreview` | 结果摘要 |
| `contentCreationDate` | `session.createdAt` | 时间元数据 |
| `contentModificationDate` | `session.updatedAt` | 排序与新鲜度 |
| `keywords` | 标题、来源名、工作目录片段 | 命中增强 |
| `namedLocation` 或自定义文本字段 | `workingDirectory` | 搜索工作目录时可命中 |
| `identifier` 相关恢复载荷 | `sessionId` | 打开结果时恢复 |

实现上建议使用 `UTType.text` 或通用文本类型来描述会话项，而不是过度拟合消息类 content type。原因是首期 Spotlight 的目标是检索会话容器，不是让 Apple Intelligence 把它当消息线程处理。

### 7.3 关键词策略

建议关键词集合包含：

- `session.title`
- `session.displaySourceTitle`
- `session.lastMessagePreview`
- `workingDirectory.lastPathComponent`
- 若 `workingDirectory` 非空，可加入完整路径片段的拆分 token

不建议直接把全部消息全文都放到 keywords：

- 会增加索引体积
- 召回过宽，结果噪音高
- 隐私暴露面扩大

更合理的首期做法是：

- 主检索基于标题、来源、目录和最后消息预览
- 若未来确认需要更强全文召回，再引入“会话摘要文本”字段，而不是原始消息全集

### 7.4 缩略图策略

首期可不提供 thumbnail。会话并不是视觉资源，缩略图对搜索价值有限。后续如果产品希望区分来源类型，可考虑基于 provider/source 生成小型 symbol 渲染图像。

---

## 8. 索引同步策略

### 8.1 触发点设计

建议把增量同步绑定到以下事件：

1. 新会话创建后
2. 会话标题更新后
3. 会话消息追加后，导致 `updatedAt` 或 `lastMessagePreview` 变化时
4. 会话来源信息变化后
5. 会话删除后

这意味着 Spotlight 同步不能只写在某一个 View 的 `.onAppear` 中，而应由服务层或持久化协调层触发。

### 8.2 推荐同步时机

最稳妥的方案是：

- **写入成功后再索引**
- **删除成功后再删索引**

也就是 Spotlight 永远跟随已提交到 SwiftData 的结果，而不是提前乐观更新。这样可避免“搜索里有结果，但数据库里没有”的反向不一致。

### 8.3 增量更新模型

对于单个会话更新：

1. 从 `Session` 构造 `CSSearchableItem`
2. 调用 `indexSearchableItems([item])`
3. 若失败，记录日志与待补偿任务

这里推荐加入一个轻量“去抖”机制，避免消息流式更新期间过于频繁地刷索引。例如：

- 标题变化立即更新
- 消息相关变化可合并为 1 到 3 秒窗口内的单次 upsert

这样既能保持较新鲜的数据，又不把 Spotlight 写入变成高频热路径。

### 8.4 删除同步

删除会话后应调用：

- `deleteSearchableItems(withIdentifiers: [sessionId])`

不要依赖系统过期删除，因为那会留下时间不可控的僵尸结果。

### 8.5 首次全量导入

应用第一次启用 Spotlight 或检测索引缺失时，应：

1. 拉取全部 `Session`
2. 过滤不应暴露到 Spotlight 的会话
3. 分批构建 `CSSearchableItem`
4. 使用 `beginBatch` / `endBatch` 写入命名索引
5. 记录本次重建状态与版本号

建议 client state 中至少编码：

- schema version
- rebuild timestamp
- last processed offset 或批次编号

---

## 9. Spotlight 打开会话的激活链路

### 9.1 恢复目标

系统搜索命中后，用户点击某条结果，应用需要稳定完成以下操作：

1. 唤起 agentGui 主窗口
2. 解析 activity 中的 searchable item 标识
3. 在 SwiftData 中查到对应 `Session`
4. 设置 `workspaceState.selectedSession = session`
5. 如当前没有工作台窗口，则先打开主窗口再应用选中态

### 9.2 恢复入口设计

推荐在 app 根级别处理 `NSUserActivity` 恢复，而不是在具体子视图处理。原因：

- Spotlight 打开 app 是应用级事件
- 恢复时可能还没有渲染到具体会话视图
- 多窗口场景下需要统一决定把结果投递到哪个工作台窗口

### 9.3 activity 解析策略

当 activityType 为 `CSSearchableItemActionType` 时：

1. 从 `userInfo` 中读取 `CSSearchableItemActivityIdentifier`
2. 将该值视为 `sessionId`
3. 通过 SwiftData fetch 查找对应会话

如果找不到会话，需要做优雅降级：

- 打开主窗口
- 展示轻量错误提示，例如“该会话已删除或不可用”
- 允许用户回到最近会话列表

### 9.4 当前会话 NSUserActivity

除了 Spotlight searchable item 恢复链路，当前显示会话还建议维护 `NSUserActivity`：

- `title = session.title`
- `persistentIdentifier = session.sessionId`
- `targetContentIdentifier = session.sessionId`
- `isEligibleForSearch = true`
- `contentAttributeSet` 与 Spotlight item 保持一致或弱化版一致

这样做的价值在于：

- 当前活跃会话具备更明确的系统活动语义
- 为未来 Quick Note、Handoff 或更细的系统恢复扩展打基础

但要强调：这只是补充链路，不替代 Core Spotlight 全量索引。

---

## 10. 隐私与安全设计

### 10.1 什么内容应该进入 Spotlight

推荐首期仅索引：

- 会话标题
- 来源标题
- 最后一条消息预览
- 工作目录片段
- 时间信息

不建议首期直接索引：

- 全量消息历史
- 工具调用内容
- 终端输出
- 提案 diff 文本
- API key、路径凭据、环境变量等敏感片段

### 10.2 会话可见性分层

agentGui 当前有本地会话、只读投影会话、外部来源会话。设计上建议增加一个 Spotlight eligibility 判定层：

- 本地普通会话：默认可索引
- 外部只读/受限来源会话：可配置是否索引
- 明显敏感的后台或系统会话：默认不索引

这层判定不应散落在 UI 中，而应集中在 `SessionSpotlightDocumentBuilder` 或其上层策略对象中。

### 10.3 数据保护级别

如果后续确认会话内容敏感度较高，可考虑使用带 `protectionClass` 的命名索引。首期可以先使用普通命名索引，但结构上应保留替换空间。

---

## 11. 失败恢复与重建机制

### 11.1 索引写入失败

单次 upsert 失败时建议：

- 记录统一日志
- 标记待补偿 sessionId
- 在下次 app 启动或空闲窗口重新尝试

不要在主线程上做无限重试。

### 11.2 索引与数据库不一致

可能场景：

- 会话已删除，但 Spotlight 仍有结果
- 会话已重命名，但搜索结果仍是旧标题
- app 崩溃导致重建只完成一半

推荐修复机制：

- 应用设置页提供“重建 Spotlight 索引”动作
- 启动时比较本地索引 schema/version 与当前版本，不一致则发起全量 rebuild
- Phase 2 引入 `CSIndexExtensionRequestHandler` 响应系统 reindex 请求

### 11.3 reindex extension 设计建议

虽然首期可以不实现 extension，但共享逻辑从第一天就应按以下方式组织：

- `SessionSpotlightDocumentBuilder`: 纯映射
- `SessionRepository` 或等效读取器: 负责列举 Session
- `SessionSpotlightIndexer`: 写入与删除

这样 extension 后续只需要复用“读取 + 构建 + 批量写入”链路，而不必复制 UI 或 App 生命周期逻辑。

---

## 12. 测试与验证方案

### 12.1 单元测试

建议新增以下测试面：

1. `SessionSpotlightDocumentBuilderTests`
   - 标题、描述、关键词映射正确
   - 空工作目录、空消息、只读来源等边界行为正确

2. `SessionSpotlightIndexerTests`
   - upsert 调用生成正确 identifier/domain
   - delete 调用使用正确 sessionId
   - rebuild 按批次提交

3. `SessionSpotlightOpenCoordinatorTests`
   - 从 activity userInfo 解析 sessionId 成功
   - 找不到会话时优雅降级

### 12.2 集成测试

需要验证：

- 新建会话后索引创建
- 修改标题后索引更新
- 删除会话后 Spotlight 项删除
- app 冷启动时通过 activity 恢复会话

考虑到系统 Spotlight 本身不易在单测中直接操作，集成测试可分两层：

- 一层验证内部协调器与 fake index adapter
- 一层保留手工 QA 脚本验证真实 Spotlight 行为

### 12.3 手工验证清单

1. 创建标题明显的新会话。
2. 等待索引刷新后在系统 Spotlight 搜索标题。
3. 点击结果，确认 app 被唤起且选中正确会话。
4. 修改会话标题，再次搜索旧标题与新标题，确认索引更新。
5. 删除会话，确认 Spotlight 不再返回该结果。
6. 触发一次全量重建，验证所有可见会话重新可搜。

对于 reindex extension，Apple 官方建议使用 `mdutil -cr <extension-bundle-id>` 强制触发重建流程，这应写入后续实施文档与 QA 手册。

---

## 13. 实施路线图

### Phase 1: 最小可用 Spotlight 集成

目标：实现可搜、可开、可增量更新。

建议任务：

1. 新增 `SessionSpotlightDocumentBuilder`
2. 新增 `SessionSpotlightIndexer`
3. 在会话新增/更新/删除关键路径接入索引同步
4. 新增 app 级 `NSUserActivity` 恢复处理
5. 实现按 `sessionId` 打开并选中会话
6. 提供手动“重建 Spotlight 索引”入口

### Phase 2: 稳定性和系统协作增强

目标：提升索引韧性与系统协作能力。

建议任务：

1. 增加 Core Spotlight Delegate extension
2. 支持系统发起的 `reindex all` / `reindex identifiers`
3. 补充失败补偿与索引版本管理
4. 为当前会话增加更完整的 `NSUserActivity` 协调器

### Phase 3: 搜索质量增强

目标：提升召回和结果质量。

建议任务：

1. 增加更精细的关键词生成与路径 token 化
2. 评估是否引入“会话摘要文本”而非单条最后消息预览
3. 评估 Apple Intelligence 摘要能力是否适合会话级实体
4. 评估消息级二级导航是否值得实现

---

## 14. 风险与权衡

### 14.1 结果召回不足 vs 隐私暴露过多

如果只索引标题，召回可能偏弱；如果把消息全文全量索引，隐私和噪音都会显著上升。

本设计选择中间路线：

- 首期索引标题、来源、工作目录片段、最后消息预览
- 观察实际召回效果后再决定是否扩大文本范围

这是一个偏谨慎但更可控的默认值。

### 14.2 立即同步 vs 去抖同步

每次消息变化都立即 upsert 可以获得最实时结果，但对流式聊天会形成高频索引写入。

本设计建议：

- 元数据类变化立即更新
- 消息文本类变化做短窗口去抖

这样既满足可用性，也控制系统负载。

### 14.3 首期是否实现 reindex extension

Apple 官方推荐实现，但它会增加 target、bundle、共享代码和调试复杂度。

本设计将其列为 Phase 2，理由是：

- 首期业务价值主要来自“可搜可开”
- 稳定性增强可以在架构预留完成后迭代补齐
- 只要共享索引逻辑从一开始抽象正确，后续补 extension 成本可控

### 14.4 多窗口路由复杂度

Spotlight 打开结果时，理论上可能存在多个工作台窗口。把结果投递给哪个窗口，是一个 UI 策略问题。

首期建议：

- 默认打开或复用主工作台窗口
- 把恢复目标统一落到该窗口的 `WorkspaceState.selectedSession`

不要在首期引入复杂的窗口选择策略。

---

## 15. 附录：Apple 文档清单

本设计直接参考的 Apple 官方文档如下：

1. `Core Spotlight`  
   https://developer.apple.com/documentation/corespotlight

2. `CSSearchableIndex`  
   https://developer.apple.com/documentation/corespotlight/cssearchableindex

3. `CSSearchableItem`  
   https://developer.apple.com/documentation/corespotlight/cssearchableitem

4. `Adding your app’s content to Spotlight indexes`  
   https://developer.apple.com/documentation/corespotlight/adding-your-app-s-content-to-spotlight-indexes

5. `Regenerating your app’s indexes on demand`  
   https://developer.apple.com/documentation/corespotlight/regenerating-your-app-s-indexes-on-demand

6. `Generating summary and priority data for indexed items`  
   https://developer.apple.com/documentation/corespotlight/generating-summary-and-priority-data-for-indexed-items

7. `NSUserActivity`  
   https://developer.apple.com/documentation/foundation/nsuseractivity

---

## 结论

对于 agentGui，把当前会话数据接入 macOS Spotlight 的正确工程方向不是“在某个 View 上顺手挂一个 `NSUserActivity`”，而是建立一条完整的 **Core Spotlight 会话索引链路**，并用 `NSUserActivity` 补强当前前台会话的系统活动语义。

推荐落地策略可以概括为一句话：

> 用 `Session.sessionId` 作为 Spotlight searchable item 的稳定主键，用命名 `CSSearchableIndex` 维护会话级索引，用 app 级恢复协调器把 Spotlight 点击事件收敛回 `WorkspaceState.selectedSession`。

这条路线与 Apple 官方文档一致，也与 agentGui 当前基于 SwiftData 的会话模型和工作台状态结构兼容，能够在不引入第二套事实源的前提下，为后续实现提供稳定基础。