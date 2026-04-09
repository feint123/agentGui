# agentGui 小说写作专项设计文档

> **日期**: 2026-04-02  
> **参考源码**: Claude Code (`claude-code-source-code-main`)  
> **目标**: 基于 Claude Code 的架构经验，为 agentGui 在小说写作场景下进行针对性设计

---

## 一、分析框架

本文档从三个维度展开分析：

1. **Claude Code 的什么机制值得借鉴** — 源码中已被验证的设计模式
2. **agentGui 的当前能力基线** — 哪些已具备、哪些缺失
3. **小说写作的特殊需求** — 有别于代码开发的创作场景

---

## 二、Claude Code 源码关键设计分析

### 2.1 分层记忆系统（`src/memdir/`）

Claude Code 实现了三级记忆作用域：

```
user scope   → ~/.claude/MEMORY.md    (跨项目持久)
project scope → .claude/MEMORY.md     (项目全局)
local scope  → .claude/MEMORY.md      (本地私有)
```

**关键能力**：
- `findRelevantMemories.ts`：在每次请求前，用一个 Sonnet 侧查询扫描所有记忆文件头部，最多取出 5 个相关记忆注入 prompt
- 记忆文件使用 Markdown frontmatter 描述主题（供检索用），正文存内容
- `truncateEntrypointContent()`：对超长 MEMORY.md 做行数/字节双限裁剪，防止撑爆 context window
- 写入策略严格：区分"临时工作笔记"和"应晋升到 CLAUDE.md/CLAUDE.local.md 的项目规范"

**对小说写作的启示**：小说写作需要更强的结构化记忆，因为角色、世界观、情节弧是长期稳定对象，而不是代码 commit 这类流式事件。

### 2.2 Skill 系统（`src/tools/SkillTool/`、`src/skills/bundled/`）

Skill 本质是带 frontmatter 的 Markdown 文件，Claude Code 的关键设计：

```markdown
---
name: remember
description: 审查并整理记忆层
when_to_use: 用户希望整理记忆时
allowed-tools: [Read, Write, Edit]
---
```

- 每个 Skill 占用 **1% context window** 的字符预算做列表展示（`SKILL_BUDGET_CONTEXT_PERCENT = 0.01`）
- Skill 支持 `argument-hint`、`arguments`（命名参数）和 `disable-model-invocation`（仅用户手动触发）
- `SkillTool` 将 Skill 包装成工具调用，模型可以主动 invoke

**对小说写作的启示**：agentGui 的 Skill 系统已非常完善，写作专项 Skill 是成本最低、收益最高的切入点。

### 2.3 内置专用 Agent（`src/tools/AgentTool/built-in/`）

Claude Code 有以下内置 Agent：

| Agent | 职责 | 工具限制 |
|---|---|---|
| `Explore` | 只读探索，快速查文件 | 禁止写/改 |
| `Plan` | 架构规划，只输出方案 | 禁止写/改 |
| `general-purpose` | 全能执行 | 无限制 |
| `verification` | 验证执行结果 | 部分限制 |

关键设计原则：**角色分离** — Explore/Plan 是只读的，执行才交给 general-purpose。这在创作场景中对应"构思不干扰写作"。

`agentMemory.ts` 实现了 Agent 专属记忆目录（`agent-memory/<agentType>/`），每个 Agent 有独立的持久状态。

### 2.4 Team 并行协作（`src/tools/TeamCreateTool/`）

多 Agent 协作模型：一个 Orchestrator + 多个 Teammate，通过共享 TaskList 和消息传递协调工作。Teammate 在每轮结束后自动变为 idle，下轮再被唤醒 — 这是异步写作协作的基础范式。

### 2.5 任务追踪（`src/tools/TodoWriteTool/`）

TODO 工具在"3步以上复杂任务"时强制启用，实时同步每个 todo 的状态（not-started / in-progress / completed）。这个设计映射到小说写作的**章节进度追踪**。

---

## 三、小说写作的特殊需求分析

小说写作与代码开发的本质差异：

| 维度 | 代码开发 | 小说写作 |
|---|---|---|
| 目标对象 | 函数、模块、接口 | 人物、世界、情节、风格 |
| 一致性要求 | 编译器验证 | 需要主观判断 |
| 版本粒度 | 行级 diff | 章节、段落、草稿轮次 |
| 上下文长度 | 通常 < 10 万字 | 长篇小说 > 30 万字 |
| 创作模式 | 确定性：需求→实现 | 发散→收敛：想法→草稿→打磨 |
| "记忆"内容 | API、架构、约定 | 人物弧、时间线、设定一致性 |
| 主要用户感受 | 正确/错误 | 好/不好/更好 |

这些差异决定了小说写作需要**独特的**（而不仅是迁移的）系统设计。

---

## 四、针对性设计方案

### 4.1 小说专属记忆架构（Novel Memory Architecture）

#### 记忆分层

借鉴 Claude Code 的三级作用域，但为小说创作定义五类专属记忆类型：

```
NovelProject/
  .novel/
    memory/
      world.md          # 世界观设定（稳定）
      characters/
        protagonist.md  # 主角档案（半稳定）
        antagonist.md
        ...
      timeline.md       # 时间线（结构化）
      style-guide.md    # 语言风格指南（稳定）
      plot-threads/
        main-arc.md     # 主线剧情（可演化）
        sub-arc-1.md
      session-notes.md  # 当前会话工作笔记（临时）
```

**稳定度分级**（直接影响记忆写入策略）：

| 记忆类型 | 稳定度 | 修改方式 | 对应 Claude Code |
|---|---|---|---|
| 世界观 / 规则 | 最高 | 需显式用户确认 | `CLAUDE.md` |
| 人物核心档案 | 高 | AI 提案 + 用户审核 | `CLAUDE.md` section |
| 情节主线 | 中 | AI 草案，用户可覆盖 | `MEMORY.md` |
| 章节笔记 | 低 | 自动写入 | local scope |
| 当前轮次工作 | 临时 | 会话结束后丢弃 | context only |

#### 记忆检索策略

Claude Code 的 `findRelevantMemories` 使用"问 Sonnet 哪些记忆相关"的方式，小说场景需要扩展为**多维检索**：

```
写当前段落前，自动检索：
  1. 本幕出现的人物 → 取该人物的最新状态档案
  2. 当前地点 → 取场景描述记忆
  3. 当前时间节点 → 取时间线记忆切片
  4. 主题关键词 → 取相关情节线记忆
  5. 风格参考 → 取风格指南
```

实现要点：记忆文件头部的 frontmatter 需要支持 `人物`、`地点`、`时间`、`情节线` 等维度标签，供检索时过滤。

### 4.2 三类专用内置 Agent

借鉴 Claude Code 的 Explore/Plan/Execute 分离模式，为小说写作定义三类内置 Agent：

#### Agent A：故事构建师（Story Architect）

```yaml
---
agentType: StoryArchitect
whenToUse: 当需要为小说规划结构、设计人物弧、构建世界观时使用
tools: [ReadFile, WriteMemory]  # 只读+写记忆，不写章节
model: claude-sonnet-4-5
---
```

职责：
- 分析已有章节，建立/更新人物档案、时间线、情节线记忆
- 规划新章节的结构方案（只输出方案，不直接写章节）
- 检测记忆中的设定冲突并报告

#### Agent B：章节写作员（Chapter Writer）

```yaml
---
agentType: ChapterWriter
whenToUse: 当需要实际写作章节内容时使用
tools: [ReadFile, ReadMemory, WriteFile]
model: claude-opus-4  # 写作质量优先
---
```

职责：
- 读取当前章节任务简报（故事构建师生成的规划）
- 读取相关记忆（人物、世界观、风格指南）
- 实际写作章节内容并保存到对应文件

#### Agent C：一致性守卫（Consistency Guard）

```yaml
---
agentType: ConsistencyGuard
whenToUse: 当章节完成后需要校验一致性时使用
tools: [ReadFile, ReadMemory]  # 纯只读
model: claude-haiku-3  # 速度优先
---
```

职责：
- 检查新章节与人物档案的一致性（性格、外貌、能力）
- 检查时间线逻辑
- 检查地名、道具、设定的连续性
- 输出问题清单，NOT 自动修改

#### 协作流程

```
用户提出"写第12章"
    ↓
StoryArchitect（规划阶段，只读）
    读取 chapters/1-11/*.md → 分析当前状态
    读取 memory/characters/*.md → 确认人物状态
    输出第12章大纲 + 场景规划
    ↓
ChapterWriter（写作阶段，读+写章节）
    读取第12章大纲
    读取相关记忆切片（自动注入）
    写作 chapters/12.md
    ↓
ConsistencyGuard（校验阶段，只读）
    对比 chapters/12.md + memory/
    输出一致性报告
    ↓
用户审核 → 接受 / 要求修改
    ↓ 接受
StoryArchitect 更新记忆（人物状态变化、时间线推进）
```

这个流程对应 Claude Code 的 Team 模式，但专为长篇叙事创作优化。

### 4.3 写作专属 Skill 库

将高频写作操作封装为 Skill，借鉴 Claude Code 的 `remember`/`skillify`/`verify` 模式：

#### Skill 1：章节续写（`chapter-continue`）

```markdown
---
name: 续写章节
description: 根据上下文续写当前章节
when_to_use: 用户需要继续写作时自动触发
arguments: [当前章节路径, 续写字数]
allowed-tools: [ReadFile, ReadMemory, WriteFile]
---

读取 {{当前章节路径}} 的最近 2000 字作为上下文。
从记忆层检索：
  - 本章出现人物的最新状态
  - 当前场景的世界观设定
  - 写作风格指南

以相同风格，续写约 {{续写字数}} 字，保持人物声音和叙事节奏。
写作时不改变已有内容，仅在文件末尾追加。
```

#### Skill 2：人物性格校调（`character-voice-tune`）

```markdown
---
name: 人物声音校调
description: 修正某段文字中特定人物的对话/行为，使其与人物档案一致
when_to_use: 用户觉得某段人物表现"不对劲"时
arguments: [人物名, 待修正段落]
allowed-tools: [ReadMemory]
---

读取 {{人物名}} 的人物档案（memory/characters/{{人物名}}.md）。
分析 {{待修正段落}} 中该人物的：
  - 对话语气是否符合人物背景
  - 行为动机是否一致
  - 情感反应是否合理

给出3种修改方案，解释各方案的侧重点，由用户选择。
```

#### Skill 3：世界观一致性检查（`worldbuilding-check`）

```markdown
---
name: 世界观检查
description: 检查章节内容中的设定一致性问题
when_to_use: 写作完成后主动检查
allowed-tools: [ReadFile, ReadMemory]
disable-model-invocation: false
---

读取 memory/world.md 中的规则和设定。
扫描用户指定的章节文本，检查：
  1. 魔法/科技/物理规则是否违反
  2. 地理/地名是否一致
  3. 时代背景细节是否合理
  
以表格形式输出所有潜在问题，标注"确认冲突"vs"可能冲突"。
```

#### Skill 4：风格统一润色（`style-harmonize`）

```markdown
---
name: 风格统一
description: 将段落调整为全书统一风格
when_to_use: 用户引入外来素材或觉得某段风格偏离时
arguments: [待润色段落]
allowed-tools: [ReadMemory]
---

读取 memory/style-guide.md 中定义的风格特征：
  - 句式长短
  - 视角（第一/第三人称）
  - 叙事节奏
  - 常用修辞手法

将 {{待润色段落}} 改写，不改变语义，仅调整风格使其符合指南。
提供对照版本（原文 vs 修改后），解释主要改动。
```

#### Skill 5：章节总结入库（`chapter-memorize`）

```markdown
---
name: 章节入库
description: 读取新章节，提取关键信息更新记忆库
when_to_use: 新章节完成后触发
arguments: [章节路径]
allowed-tools: [ReadFile, ReadMemory, WriteMemory]
---

读取 {{章节路径}} 的完整内容。
提取并更新以下记忆：

1. 人物状态变化 → 更新对应人物档案
2. 新引入的场景/地点 → 更新 memory/world.md
3. 时间线推进 → 更新 memory/timeline.md
4. 情节线进展 → 更新对应 memory/plot-threads/*.md

对每处写入，给出"写入内容"和"理由"，用户确认后才实际写入。
```

### 4.4 章节任务管理（Chapter Task Board）

Claude Code 的 `TodoWriteTool` 强制在复杂任务中使用任务追踪，小说写作需要类似但更精细的结构：

```swift
struct ChapterTask {
    var id: UUID
    var chapterNumber: Int
    var title: String
    var status: ChapterStatus      // planned / drafting / drafted / reviewing / done
    var targetWordCount: Int
    var currentWordCount: Int
    var synopsis: String           // 250字以内的章节剧情摘要
    var linkedMemoryFiles: [String] // 与本章关联的记忆文件
    var blockedBy: [UUID]          // 前置章节依赖
}
```

**UI 设计要点**：
- Chapter Task Board 作为 WorkbenchSidebarView 的一个独立面板
- 用类似 Scrivener Cork Board 的卡片视图展示各章节状态
- 当 ConsistencyGuard 发现问题时，在对应章节卡片上显示警告徽标
- 拖拽卡片可调整章节顺序

### 4.5 小说项目上下文注入（Novel Context Injection）

借鉴 Claude Code `context.ts` 中的 `getGitStatus()` / `getSystemContext()`，在每次请求前自动注入当前小说项目上下文：

```swift
/// 类比 Claude Code 的 getSystemContext()
func getNovelProjectContext(for chapter: ChapterTask) async -> String {
    """
    ## 当前写作项目上下文
    
    **项目**: \(project.title)（\(project.genre)）
    **当前章节**: 第 \(chapter.chapterNumber) 章「\(chapter.title)」
    **当前进度**: \(chapter.currentWordCount) / \(chapter.targetWordCount) 字
    **上一章摘要**: \(previousChapterSynopsis)
    
    ## 已注入记忆
    \(injectedMemoryFiles.map { "- \($0)" }.joined(separator: "\n"))
    """
}
```

这段上下文在每次请求时自动追加到系统 prompt，确保 AI 始终知道"我在写什么项目、写到了哪里"。

### 4.6 渐进式记忆晋升（Memory Promotion Workflow）

Claude Code 的 `remember` Skill 有一套完整的记忆分层晋升流程：
`auto-memory → CLAUDE.md / CLAUDE.local.md`

小说场景的对应机制：**草稿边界原则**

```
临时笔记 (session context)
    ↓ 章节完成后
章节摘要 (session-notes.md)
    ↓ 用户审核
情节记忆 (plot-threads/*.md)
    ↓ 多章累积形成规律
人物档案 (characters/*.md)
    ↓ 核心设定稳定后
世界观基石 (world.md) ← 最高稳定度，修改需二次确认
```

UI 实现：当 AI 检测到值得晋升的信息时，以"记忆卡片"（类似 Claude Code 的确认卡片）呈现，用户可以：
- **接受**：写入对应记忆文件
- **编辑后接受**：修改内容再写入
- **忽略本次** / **永不记录此类内容**

---

## 五、架构影响评估

### 5.1 需要新增的 Swift 模型

```swift
// 小说项目
@Model final class NovelProject { ... }

// 章节任务
@Model final class ChapterTask { ... }

// 记忆条目（取代纯文件系统，便于 SwiftData 检索）
@Model final class NovelMemoryRecord {
    var type: MemoryType  // character/world/timeline/style/plotThread
    var tags: [String]    // [人物名、地名、章节范围...]
    var content: String
    var stability: MemoryStability  // stable/evolving/temporary
    var pendingPromotion: Bool
}
```

### 5.2 需要新增的 Service

| Service | 职责 | 类比 Claude Code |
|---|---|---|
| `NovelMemoryRetrievalService` | 按维度检索相关记忆 | `findRelevantMemories.ts` |
| `NovelContextInjectionService` | 构建每次请求的小说上下文 | `getSystemContext()` |
| `ChapterConsistencyService` | 分析并报告一致性问题 | `verification agent` |
| `MemoryPromotionCoordinator` | 管理临时→持久记忆晋升流程 | `remember` skill 流程 |

### 5.3 需要扩展的 View

| View | 扩展方向 |
|---|---|
| `WorkbenchSidebarView` | 增加 `ChapterBoardPanel`、`NovelMemoryPanel` |
| `AgentTeamSessionView` | 适配小说写作三 Agent 的显示（StoryArchitect/Writer/Guard） |
| `SkillsView` | 增加写作 Skill 分类展示 |
| `MemoryConfirmationView`（新建） | 记忆晋升确认卡片 |

---

## 六、优先级路线图

### Phase 1：基础写作体验（2 周）

- [ ] `chapter-continue`、`style-harmonize` 两个 Skill
- [ ] `session-notes.md` 会话记忆自动写入
- [ ] 章节字数统计显示在 WorkbenchSidebar

### Phase 2：结构化记忆（3 周）

- [ ] `NovelMemoryRecord` 模型 + `NovelMemoryRetrievalService`
- [ ] 人物档案、世界观、风格指南的记忆文件结构
- [ ] `chapter-memorize` Skill（章节入库）
- [ ] 记忆晋升确认卡片 UI

### Phase 3：多 Agent 写作流（4 周）

- [ ] `StoryArchitect` + `ChapterWriter` 两个内置 Agent
- [ ] `ChapterTask` 任务板 UI
- [ ] 自动注入小说项目上下文

### Phase 4：一致性守卫（2 周）

- [ ] `ConsistencyGuard` Agent
- [ ] `worldbuilding-check` Skill
- [ ] 章节完成后自动触发一致性报告

---

## 七、与现有架构的衔接

### 与 AgentTeam 系统衔接

agentGui 已有完整的 `AgentTeamSessionState`、`AgentTeamMissionBrief`、`AgentTeamTaskBoard` 实现。小说写作三 Agent 可以**直接复用**这套基础设施：

- `AgentTeamMissionBrief` → 映射为"章节写作任务简报"
- `AgentTeamTaskBoard` → 映射为"章节任务板"
- `AgentTeamClaimCoordinator` → 管理 Writer/Guard 的任务认领

### 与 Memory 系统衔接

agentGui 已有 `MemoryConsolidationService`、`RelevantMemoryRecallService` 等完整实现。只需要：
1. 扩展 `MemoryKind` 枚举，增加小说专属类型（`character`/`worldBuilding`/`plotThread`/`styleGuide`）
2. 扩展 `MemoryRetrievalIntent`，增加按角色/地点/章节范围的检索意图
3. 调整 `MemoryConsolidationPromptBuilder` 的提示词，理解小说记忆的稳定度分级

### 与 Skill 系统衔接

agentGui 已有完整的 Skill 系统（`SkillService`、`SkillInvocationProcessor`、`SkillArgumentSubstitution`）。写作 Skill 直接以 Markdown 文件形式放入 `~/.agents/skills/` 目录即可使用，**无需代码改动**。

---

## 八、设计原则总结

| 原则 | Claude Code 的做法 | agentGui 小说写作的映射 |
|---|---|---|
| **角色分离** | Explore（只读）≠ Execute（读写） | StoryArchitect（规划）≠ ChapterWriter（执行）≠ ConsistencyGuard（验证） |
| **记忆分层** | user/project/local + 稳定度分级 | 世界观/人物/情节/笔记 + 稳定度分级 |
| **按需检索** | 侧查询选出 top-5 相关记忆注入 | 按章节维度精确检索，而非语义相似检索 |
| **写入前确认** | `remember` skill 提案未经确认不写入 | 章节入库信息提案，用户确认后才更新记忆 |
| **任务可见性** | TodoWriteTool 实时同步状态 | ChapterTask Board 全程可见，章节状态透明 |
| **上下文自注入** | `getSystemContext()` 每次自动构建 | `getNovelProjectContext()` 每次自动追加小说状态 |

---

*本设计基于 Claude Code `src/` 源码分析（2026-04-02），针对 agentGui Swift/SwiftUI/SwiftData 技术栈提出。所有数据结构建议仅为概念性设计，具体实现应结合当前 agentGui 代码库约定进行调整。*
