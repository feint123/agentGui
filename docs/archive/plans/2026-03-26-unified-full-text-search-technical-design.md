# 统一全文搜索技术设计文档

> **文档状态:** 研究草稿 · 2026-03-26  
> **作者:** 基于 Apple 官方文档、SQLite FTS5 文档与 agentGui 现有架构的调研分析  
> **目标平台:** macOS 14+  
> **关联代码:** `agentGui/Models/Session.swift`, `agentGui/Models/Message.swift`, `agentGui/Models/AppSettings.swift`, `agentGui/Services/SkillService.swift`, `agentGui/ViewModels/SessionCatalogViewModel.swift`, `agentGui/AppCommands/Palette/QuickOpenProvider.swift`, `agentGui/AppCommands/Indexes/WorkspaceFileSearchIndex.swift`, `agentGui/Utilities/WorkspaceState.swift`, `agentGui/agentGuiApp.swift`

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [Apple SearchKit 调研结论](#2-apple-searchkit-调研结论)
3. [现有代码基线](#3-现有代码基线)
4. [需求定义与非目标](#4-需求定义与非目标)
5. [方案选型与结论](#5-方案选型与结论)
6. [推荐架构](#6-推荐架构)
7. [统一数据模型设计](#7-统一数据模型设计)
8. [索引构建与增量同步](#8-索引构建与增量同步)
9. [查询、排序与高亮策略](#9-查询排序与高亮策略)
10. [与现有 UI/服务的集成方式](#10-与现有-ui服务的集成方式)
11. [线程模型、SwiftData 边界与故障恢复](#11-线程模型swiftdata-边界与故障恢复)
12. [实施路线图](#12-实施路线图)
13. [风险与权衡](#13-风险与权衡)
14. [附录：参考资料](#14-附录参考资料)

---

## 1. 背景与目标

agentGui 当前已经具备多处“搜索”入口，但它们本质上还不是统一的全文搜索系统：

- 会话列表搜索只覆盖 `title`、来源标题和 `lastMessagePreview`
- 工作区检索主要是路径/文件名匹配
- 技能依赖 `SkillService` 扫描本地目录并在内存中缓存，尚无统一索引
- 命令面板能够聚合结果，但底层没有跨内容域的检索编排层

这导致当前搜索能力有三个明显问题：

1. **会话搜索不是真正的全文搜索**，无法按历史消息正文稳定命中。
2. **工作区、技能、未来变更提案等内容源各自为政**，难以共享排序、过滤、索引生命周期和 UI 交互模型。
3. **架构不可扩展**，每接入一种新内容源都要在 UI 层重新发明一套搜索逻辑。

本设计的目标是建立一套 **统一、模块化、可扩展** 的全文搜索架构，满足以下要求：

- 首期优先落地 **会话搜索全文化**
- 未来平滑扩展到 **工作区文件内容**、**技能文档**、**变更提案** 等内容域
- 对上提供统一 `SearchService`
- 对下允许替换或组合不同索引后端
- 与现有 `SwiftData + SwiftUI + @MainActor` 架构兼容

本次选型结论为：

> **主后端采用 SQLite FTS5。SearchKit 作为 Apple 官方能力调研对象与可选后端，不作为主实现路径。**

---

## 2. Apple SearchKit 调研结论

### 2.1 SearchKit 的定位

Apple 官方将 `Search Kit` 定位为一套“索引并搜索自然语言文档”的 macOS 原生全文检索能力。当前公开 API 仍然可用，核心接口包括：

- `SKIndexCreateWithURL`
- `SKIndexOpenWithURL`
- `SKIndexAddDocumentWithText`
- `SKIndexFlush`
- `SKIndexCompact`
- `SKSearchCreate`
- `SKSearchFindMatches`

从 API 形态看，SearchKit 的能力重点是：

- 应用自己管理索引文件
- 向索引中写入文档文本
- 使用异步搜索对象执行查询
- 返回匹配文档与分数

### 2.2 SearchKit 的优点

如果只从“是否能做全文搜索”这个问题出发，SearchKit 具备以下优势：

- 是 Apple 官方提供的本地索引能力
- 与 macOS 平台适配天然一致
- API 明确覆盖索引创建、追加、刷新、压缩和查询
- 适合 app 自主管理的文档搜索场景

### 2.3 SearchKit 不适合作为本项目主后端的原因

尽管 SearchKit 能做全文索引，但它不适合作为 agentGui 统一搜索系统的主后端，原因主要有五点：

#### 2.3.1 API 过于底层且偏 C 风格

SearchKit 暴露的是 Core Services 时代的 C API。对于当前以 SwiftUI、SwiftData、`@Observable`、`@MainActor` 为主的工程体系来说：

- 类型桥接成本高
- 可测试性一般
- 高亮、过滤、排序等二次能力要自己再封装
- 错误恢复与调试体验不如 SQLite 生态成熟

#### 2.3.2 不利于做跨内容域的统一结构化检索

本项目未来不只是“搜文本”，而是要同时处理：

- 会话标题、正文、来源、工作目录
- 工作区路径、文件名、文件内容
- 技能元数据、说明文档、示例内容
- 未来可能的 diff、提案、注释、笔记

这些对象除了全文字段，还需要：

- 领域类型过滤
- 作用域过滤
- 排序权重
- 去重与折叠
- 高亮摘要
- 批量重建和增量更新

SQLite FTS5 可以很自然地把“全文索引表”和“元数据表”组合起来统一处理；SearchKit 更适合作为纯文档索引引擎，而不是本地搜索数据库的中心。

#### 2.3.3 不利于统一管理多来源索引状态

agentGui 中一部分数据来自 SwiftData，一部分来自文件系统，一部分来自内存服务：

- `Session` / `Message` 在 SwiftData 中
- workspace 根路径来自 `WorkspaceState` / `AppSettings`
- `SkillService` 扫描 `~/.claude/skills`

如果采用 FTS5，可以把“索引文档表、元数据表、版本表、任务表”统一放进一个 SQLite 数据库中，方便：

- 标记脏文档
- 记录上次同步时间
- 存储 schema version
- 做 rebuild / compact / vacuum

SearchKit 只覆盖索引本身，不擅长承担这些外围状态管理职责。

#### 2.3.4 FTS5 的查询能力与生态更适合应用内搜索

FTS5 直接支持：

- `MATCH`
- 排序 `ORDER BY rank`
- `highlight(...)`
- `snippet(...)`
- 前缀查询
- 短语查询
- `NEAR`
- 布尔查询
- 外部内容表与内容无关索引模式

这些能力更贴近 agentGui 应用内统一搜索的目标，也更方便和 SQL 条件、聚合与元数据过滤合并。

#### 2.3.5 后续可移植性更好

即使当前目标平台是 macOS，统一搜索架构仍然应该尽量避免被单一平台专有 API 锁死。采用 FTS5 做核心后端后：

- SearchKit 仍可作为 macOS 特定实验后端
- 未来若引入 iOS/iPadOS 版本，后端选择更自由
- 单元测试可直接基于临时 SQLite 数据库跑，不依赖 Core Services 行为

### 2.4 对 SearchKit 的最终判断

SearchKit 在本项目中的最佳角色不是“主后端”，而是：

- Apple 官方能力调研对象
- 备选或实验性后端
- 如果未来有极端 macOS-only 优化需求，可作为某些内容域的专用索引实现

因此，本设计不否定 SearchKit，而是将其定位为 **可替换后端之一**，但首选不使用。

---

## 3. 现有代码基线

### 3.1 会话与消息模型适合作为首个全文化对象

`Session` 当前已经具备稳定标识和基础元数据：

- `sessionId`
- `title`
- `createdAt`
- `updatedAt`
- `workingDirectory`
- `displaySourceTitle`
- `lastMessagePreview`

`Message` 提供：

- `textContent`
- `timestamp`
- `sequence`

这意味着“会话级全文搜索”的最自然做法不是把每条消息直接暴露为独立结果，而是：

- 索引 `Session` 作为主结果实体
- 将消息正文拼接或分段映射为可搜索文本
- 查询结果最终回到 `Session`

### 3.2 当前搜索入口分散

现有可复用入口主要有：

- `SessionCatalogViewModel`：会话列表搜索
- `QuickOpenProvider`：命令面板聚合结果
- `WorkspaceFileSearchIndex`：工作区路径检索
- `SkillService`：技能元数据与文档内容来源

这些入口说明当前应用已经具备“搜索 UI”，但缺少统一的“搜索域模型”和“索引后端”。

### 3.3 架构约束

当前项目有几个重要约束：

- SwiftData 仍然是事实主存储，搜索库不能反向变成事实源
- 多个关键服务和 ViewModel 运行在 `@MainActor`
- 文件系统扫描、LSP、变更捕获等耗时任务已倾向在后台执行
- workspace 和 skill 并非完整 SwiftData 模型，更多依赖路径与缓存

因此搜索系统必须满足：

- **读取事实源时尊重主线程边界**
- **索引构建在后台执行**
- **查询可以尽量脱离 SwiftData 热路径**

---

## 4. 需求定义与非目标

### 4.1 功能需求

首期与后续总体需求如下：

1. 支持会话标题、来源、工作目录、消息正文的全文搜索。
2. 支持未来扩展到 workspace 文件内容与 skill 文档。
3. 支持统一结果模型、统一排序与统一过滤。
4. 支持增量更新、批量重建、索引损坏恢复。
5. 支持命令面板、会话列表、未来全局搜索面板复用同一后端。

### 4.2 非目标

首期不做：

- 语义向量检索
- 跨设备同步索引
- 系统级 Spotlight 暴露
- 消息级独立搜索结果导航
- OCR、附件二进制解析、PDF 富提取

首期优先解决的是 **本地统一全文搜索架构**，而不是把所有搜索形态一次做满。

---

## 5. 方案选型与结论

### 5.1 方案 A：SearchKit 直连型

设计方式：

- 每个内容域实现自己的 SearchKit 文档映射
- UI 通过统一适配层调用 SearchKit 查询

优点：

- 平台原生
- 文本索引能力可用

缺点：

- C API 封装重
- 元数据管理薄弱
- 不利于跨域统一排序与过滤
- 测试与迁移成本高

结论：

> 不推荐作为主方案。

### 5.2 方案 B：抽象后端型，首版默认 SearchKit

设计方式：

- 先定义 `SearchBackend`
- 首版实现 `SearchKitBackend`
- 后续再引入 `SQLiteFTSBackend`

优点：

- 理论上可替换

缺点：

- 首版仍然会被 SearchKit 的底层设计牵着走
- 统一元数据模型仍需重做

结论：

> 比 A 更好，但不是本次最优解。

### 5.3 方案 C：SQLite FTS5 统一搜索数据库

设计方式：

- 使用单独的搜索数据库作为“索引投影层”
- 以 FTS5 表承载全文，以普通表承载元数据和同步状态
- 每个内容域只负责把事实源投影为统一搜索文档

优点：

- 最适合跨内容域统一设计
- 查询、排序、过滤、高亮天然统一
- 易测、易 debug、易重建
- 与 SwiftData、文件系统、内存缓存都容易对接

缺点：

- 需要维护一份额外搜索数据库
- 需要处理投影同步与 rebuild

结论：

> **推荐方案。**

### 5.4 最终结论

本项目应采用：

- **主后端：SQLite FTS5**
- **上层：统一 `SearchService`**
- **中层：按内容域拆分 provider**
- **SearchKit：保留为备选实验后端，不进入首期主链路**

---

## 6. 推荐架构

### 6.1 分层结构

推荐将搜索系统拆为四层：

```text
UI / ViewModel
    ↓
SearchService
    ↓
SearchProvider / SearchDomainAdapter
    ↓
SearchBackend (SQLite FTS5)
```

各层职责如下：

#### 6.1.1 SearchService

统一对外 API，负责：

- 接收查询
- 调用一个或多个 provider
- 合并、排序、裁剪结果
- 返回统一 `SearchResult`

它不关心具体事实源来自 SwiftData、文件系统还是内存服务。

#### 6.1.2 SearchProvider / SearchDomainAdapter

每个内容域一个 provider，例如：

- `SessionSearchProvider`
- `WorkspaceSearchProvider`
- `SkillSearchProvider`
- `ChangeProposalSearchProvider`

provider 负责：

- 定义文档主键
- 从事实源提取可搜索文本与元数据
- 监听或触发增量同步
- 将命中结果反解回领域对象引用

#### 6.1.3 SearchBackend

统一后端协议，核心能力包括：

- 写入/删除文档
- 批量重建
- 执行查询
- 返回原始命中与高亮片段
- 维护 schema version 与索引状态

首版实现为 `SQLiteFTSBackend`。

#### 6.1.4 SearchIndexingCoordinator

这是独立于查询链路的后台协调器，负责：

- 管理 rebuild
- 合并脏文档更新
- 节流写入
- 记录失败重试

它是“搜索系统的大脑”，避免每个 provider 各自起线程和刷索引。

### 6.2 建议目录结构

```text
agentGui/
  Services/Search/
    SearchService.swift
    SearchTypes.swift
    SearchProvider.swift
    SearchBackend.swift
    SearchIndexingCoordinator.swift
    SQLite/
      SQLiteFTSBackend.swift
      SearchDatabaseMigrator.swift
      SearchDatabasePaths.swift
    Providers/
      SessionSearchProvider.swift
      WorkspaceSearchProvider.swift
      SkillSearchProvider.swift
```

---

## 7. 统一数据模型设计

### 7.1 领域级模型

建议定义以下公共类型：

```swift
struct SearchQuery {
    var text: String
    var scopes: Set<SearchScope>
    var limit: Int
    var includeSnippets: Bool
}

enum SearchScope: String, Hashable {
    case sessions
    case workspaceFiles
    case skills
    case changeProposals
}

struct SearchResult: Identifiable {
    var id: String
    var scope: SearchScope
    var title: String
    var subtitle: String?
    var snippet: String?
    var score: Double
    var payload: SearchResultPayload
}
```

`payload` 用于承载可导航引用，例如：

- `sessionId`
- 文件路径
- `skillID`
- `changeProposalID`

### 7.2 搜索数据库模型

建议采用“两类表 + 一个 FTS 表”的结构。

#### 7.2.1 文档元数据表

```sql
CREATE TABLE search_documents (
    document_id TEXT PRIMARY KEY,
    scope TEXT NOT NULL,
    title TEXT NOT NULL,
    subtitle TEXT,
    source_id TEXT NOT NULL,
    source_version TEXT,
    workspace_root TEXT,
    updated_at REAL NOT NULL,
    ranking_bucket INTEGER NOT NULL DEFAULT 0,
    metadata_json TEXT
);
```

字段说明：

- `document_id`: 全局唯一，例如 `session:<sessionId>`
- `scope`: 领域类型
- `source_id`: 领域内稳定 ID
- `source_version`: 用于增量同步判定
- `metadata_json`: 承载少量可扩展信息，避免过早过度建模

#### 7.2.2 FTS 虚拟表

```sql
CREATE VIRTUAL TABLE search_fts USING fts5(
    document_id UNINDEXED,
    title,
    body,
    keywords,
    tokenize = 'unicode61'
);
```

建议：

- `title` 用于高权重命中
- `body` 存正文摘要、消息聚合文本、文件内容
- `keywords` 存来源名、路径片段、标签等短词字段

#### 7.2.3 索引状态表

```sql
CREATE TABLE search_sync_state (
    provider_id TEXT PRIMARY KEY,
    last_full_rebuild_at REAL,
    last_cursor TEXT,
    schema_version INTEGER NOT NULL
);
```

此表用于：

- 记录 provider 级增量同步游标
- 控制 rebuild
- 做迁移兼容

### 7.3 文档主键规范

所有 provider 必须遵循统一主键格式：

- `session:<sessionId>`
- `workspace-file:<absolutePath>`
- `skill:<directoryName>`
- `change-proposal:<proposalID>`

这样可以避免不同内容域之间主键冲突，也利于调试。

### 7.4 会话域的投影策略

会话搜索不建议直接把每条 `Message` 做成独立文档，而建议：

- 每个 `Session` 一个主文档
- `title` = 会话标题
- `subtitle` = 来源 + 工作目录简写
- `body` = 最近 N 条消息正文拼接或滚动摘要
- `keywords` = 来源标题、工作目录分词、会话标签

原因：

- UI 当前导航单位是 `Session`
- 命令面板与会话列表最终都落到打开会话
- 消息级结果会大幅增加结果噪音与同步成本

未来如果确实需要消息级定位，可在二期增加 `session-message:<messageID>` 子文档类型。

### 7.5 workspace 与 skill 的投影策略

#### workspace 文件

- `title`: 文件名
- `subtitle`: 相对路径
- `body`: 文件文本内容
- `keywords`: 扩展名、目录名、仓库名

#### skill

- `title`: skill 名称
- `subtitle`: skill 目录或分类
- `body`: `SKILL.md` 正文、示例、描述
- `keywords`: 目录名、启用状态、标签

---

## 8. 索引构建与增量同步

### 8.1 索引生命周期

统一搜索索引应支持四种操作：

1. **upsert**：新增或更新单个文档
2. **delete**：删除单个文档
3. **batch rebuild**：全量重建某一 provider 或全部 provider
4. **vacuum/optimize**：数据库维护

### 8.2 会话域同步策略

`SessionSearchProvider` 应优先采用“事件驱动 + 定时兜底”的混合模式：

- 会话创建：upsert
- 会话标题变更：upsert
- 消息新增：延迟合并后 upsert 对应 session 文档
- 会话删除：delete
- 应用启动：扫描最近更新的会话做一次 reconciliation

这里不建议“每来一条消息就立即同步数据库”，而建议：

- 在 provider 中标记 session 为 dirty
- 交给 `SearchIndexingCoordinator` 做 300ms - 1000ms 级节流合并

这样能明显减少写放大。

### 8.3 workspace 文件同步策略

workspace 内容量通常远大于会话，因此要分阶段：

#### Phase 1

- 先沿用 `WorkspaceFileSearchIndex` 的路径扫描经验
- 只建立路径级和文件名级索引

#### Phase 2

- 增加文件内容索引
- 通过文件修改时间和大小做增量判断
- 对超大文件、二进制文件、忽略目录应用策略过滤

建议复用现有工作区刷新与文件树扫描触发点，不额外引入第二套目录监听系统。

### 8.4 skill 同步策略

`SkillService` 当前已经缓存可用技能列表，因此 skill provider 的首版可以很轻：

- app 启动或技能目录变更后扫描一次
- 对每个 skill 读取 `SKILL.md`
- 根据文件内容 hash 或修改时间判定是否需要 upsert

### 8.5 全量重建

以下情况触发全量重建：

- 搜索数据库 schema 升级
- 用户显式点击“重建索引”
- 检测到索引文件损坏
- provider 同步游标失效

重建顺序建议：

1. sessions
2. skills
3. workspace files

原因是会话与技能数据量更可控、用户价值更高，适合作为优先可用内容域。

---

## 9. 查询、排序与高亮策略

### 9.1 查询流程

标准查询流程应为：

1. UI 构造 `SearchQuery`
2. `SearchService` 归一化输入
3. `SearchBackend` 执行 FTS5 查询
4. 结合元数据表做过滤和排序修正
5. provider 将命中反解为 `SearchResult`

### 9.2 排序策略

推荐采用“基础相关性 + 领域加权 + 新鲜度加权”的混合排序：

```text
finalScore =
    textRelevance
  + scopeWeight
  + recencyBoost
  + exactTitleBoost
```

建议初始规则：

- 标题精确命中 > 正文命中
- 会话标题命中 > 会话消息正文命中
- 最近更新的会话适度加分
- 已启用技能可略高于未启用技能

### 9.3 高亮与摘要

FTS5 可以直接通过 `highlight(...)` 和 `snippet(...)` 生成高亮摘要。

建议：

- 会话结果显示 1 段 snippet
- workspace 文件结果显示 1-2 段 snippet
- skill 结果显示命中说明段

这样 UI 层不需要重新自己做字符串切片和标注。

### 9.4 空查询与前缀查询

对空查询不应走 FTS，而应回落到：

- 最近会话
- 最近 workspace
- 常用技能

对短查询建议启用前缀查询，但要控制性能成本。可采用：

- 长度 >= 2 时启用标题前缀匹配
- 长度 >= 3 时启用正文前缀匹配

---

## 10. 与现有 UI/服务的集成方式

### 10.1 会话列表

当前 `SessionCatalogViewModel` 的内存过滤逻辑应逐步替换为：

- 查询短、索引未就绪时：保留现有本地过滤兜底
- 查询较完整且索引可用时：走 `SessionSearchProvider`

这样可以降低切换风险。

### 10.2 命令面板

`QuickOpenProvider` 是统一搜索服务的最佳首个消费者，因为它已经具备多结果源聚合能力。

推荐演进方向：

- 用 `SearchService.search(...)` 替代零散 provider 调用
- 先接 sessions + skills
- 再接 workspace files

### 10.3 技能列表与设置页

未来技能管理页可以复用同一套搜索结果，不再单独在 UI 层做字符串过滤。

### 10.4 搜索状态反馈

建议暴露以下状态给 UI：

- `isIndexReady`
- `isRebuilding`
- `lastUpdatedAt`
- `lastError`

这样可以让命令面板或设置页提示：

- 正在建立索引
- 某个内容域尚未就绪
- 可以手动重建

---

## 11. 线程模型、SwiftData 边界与故障恢复

### 11.1 线程边界

建议遵循以下规则：

- SwiftData 读取：在与现有架构一致的 actor 边界内完成
- 文档投影构造：可在后台进行
- SQLite 写入与查询：由专用串行 actor 或队列管理

换句话说：

- **SwiftData 是事实源**
- **SQLite FTS 是搜索投影**
- 二者不能交叉写入或互相替代

### 11.2 搜索数据库位置

建议将搜索数据库放在 app 自有 Application Support 目录，例如：

```text
~/.agentgui/search/search-index.sqlite
```

与当前 SwiftData 主库分离，原因是：

- 生命周期不同
- 故障恢复不同
- vacuum / rebuild 不应影响主库

### 11.3 故障恢复

搜索库损坏时，系统应：

1. 记录错误
2. 删除损坏的搜索库文件
3. 重建空库
4. 异步触发全量 rebuild

UI 层应看到“搜索索引正在恢复”，而不是直接静默失败。

### 11.4 一致性原则

搜索结果允许短暂最终一致，但不能长期错误。因此建议目标是：

- 会话标题与删除：尽量秒级同步
- 消息正文：允许亚秒到数秒级延迟
- workspace 内容：允许更长延迟

---

## 12. 实施路线图

### Phase 1：搜索内核与会话全文搜索

- 新建 `SearchService`、`SearchBackend`、`SearchProvider`
- 实现 `SQLiteFTSBackend`
- 接入 `SessionSearchProvider`
- 在 `QuickOpenProvider` 和会话列表中启用会话全文搜索
- 提供“重建搜索索引”入口

### Phase 2：skill 搜索

- 接入 `SkillSearchProvider`
- 将 `SKILL.md` 投影进 FTS
- 命令面板接入 skill 全文结果

### Phase 3：workspace 路径 + 内容搜索

- 先接路径/文件名统一结果
- 后接文件内容索引
- 增加大文件与二进制文件过滤策略

### Phase 4：高级能力

- 消息级深链命中
- 混合排序调优
- 备选 `SearchKitBackend` 实验
- 语义检索或 embedding 混合召回

---

## 13. 风险与权衡

### 13.1 维护双存储

采用 FTS5 的代价是维护一份额外搜索数据库。但这是可接受的，因为它换来了：

- 更清晰的边界
- 更强的可扩展性
- 更低的 UI 耦合

### 13.2 文本聚合策略可能影响结果质量

会话结果如果只聚合最近 N 条消息，可能漏掉更早内容；如果聚合过多，又会放大写入与索引体积。

建议首版采用：

- 最近消息滚动窗口
- 标题、来源、工作目录权重更高

后续再根据真实使用反馈调整。

### 13.3 workspace 文件索引体量可能快速膨胀

因此 workspace 应分阶段接入，并明确：

- 忽略二进制文件
- 限制单文件体积
- 支持按 workspace root 重建和清理

### 13.4 SearchKit 的机会成本

本次不以 SearchKit 为主后端，意味着不会立即利用 Apple 的平台专有索引能力。但考虑到项目目标是统一、模块化、可扩展，这个取舍是合理的。

---

## 14. 附录：参考资料

### Apple SearchKit

- Apple Developer Documentation: `Search Kit`
- Apple Developer Documentation: `SKIndexCreateWithURL`
- Apple Developer Documentation: `SKIndexAddDocumentWithText`
- Apple Developer Documentation: `SKSearchCreate`
- Apple Developer Documentation: `SKSearchFindMatches`

核心结论：

- SearchKit 仍可用
- API 能覆盖本地全文索引
- 但更适合作为底层文档搜索引擎，而不是本项目统一搜索数据库中心

### SQLite FTS5

- SQLite Documentation: `FTS5 Extension`

核心结论：

- FTS5 原生支持全文表、相关性排序、高亮、摘要、前缀、布尔与邻近查询
- 非常适合作为应用内统一搜索后端

### 仓库内相关文档

- `docs/plans/2026-03-25-macos-spotlight-session-search-technical-design.md`

该文档讨论的是 **系统级 Spotlight 集成**；本文档讨论的是 **应用内统一全文搜索架构**。两者并不冲突：

- 本文解决 app 内搜索统一化
- Spotlight 集成可在后续将会话结果进一步投影到系统搜索

