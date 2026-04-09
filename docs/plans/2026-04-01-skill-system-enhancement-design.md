# Skill 系统增强设计

**Goal:** 基于对 Claude Code v2.x 解包源码的对照分析，识别 `skills/` 目录、`SkillTool`、`BundledSkills`、`loadSkillsDir.ts` 等模块中可迁移到 agentGui 的设计，形成一份面向当前 Swift/SwiftUI 架构的 Skill 系统增强方案。

**Architecture:** 不复制 Claude Code 的具体 TypeScript 实现；仅抽取其有效设计模式，并映射到 agentGui 现有的 `SkillService`、`Skill` 模型、`ClaudeService`、agent loop 与 SwiftUI 工作台中。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, SwiftAnthropic, 现有 SkillService/Skill/SkillsView

---

## 1. 结论先行

agentGui 当前的 skill 系统停留在"发现 + 静态注入"层，而 Claude Code 已经把 skill 做成了一等运行时公民：

| 维度 | agentGui 现状 | Claude Code 基线 |
|------|-------------|----------------|
| 发现范围 | 仅 `~/.claude/skills/` | managed / user / project / additional dirs / MCP |
| 动态发现 | ❌ | ✅ 文件操作时自动 walk-up |
| 条件激活 | ❌ | ✅ `paths` frontmatter 按文件路径激活 |
| 模型主动调用 | ❌ 无 SkillTool | ✅ SkillTool 独立工具 |
| 两种执行模式 | ❌ 全部全文注入 | ✅ inline / fork（子代理） |
| 参数传递 | ❌ | ✅ args + `$ARGUMENTS` + named args |
| allowedTools 限制 | ❌ | ✅ skill 级别工具白名单 |
| 模型覆盖 | ❌ | ✅ skill frontmatter `model:` |
| 内置技能 | ❌ | ✅ skillify, verify, remember, loop 等 |
| Token 预算管理 | ❌ 全文注入 | ✅ 1% context window 上下文预算 |
| 技能钩子 | ❌ | ✅ hooks frontmatter |
| 参考文件提取 | ❌ | ✅ `files:` 按需 lazy 解压到磁盘 |
| Shell 指令内嵌 | ❌ | ✅ `` !`cmd` `` 语法 |

可迁移价值最高的五类改进（按落地难度排序）：

1. **扩展 SkillManifest**：把 whenToUse、allowedTools、model、effort、argument-hint、argumentNames、paths、version 等字段读进 `Skill` 模型，成本低但影响广。
2. **SkillInvocationTool**：让模型可以通过工具调用主动触发 skill（inline 展开 prompt），效果最直接，不需要改 UI。
3. **Fork 执行模式**：skill 以独立子代理运行，有隔离 context 和独立 token 预算，复杂 skill 更稳定。
4. **动态项目技能发现 + 条件激活**：`.claude/skills/` 路径向上查找，按 `paths` 激活——让 skill 随文件上下文自动浮现，无需用户手动启用。
5. **内置技能注册表 + Skillify 工具**：允许 agentGui built-in agent 将当前会话的成功流程直接提炼成 skill 文件写入磁盘，形成知识可积累的闭环。

---

## 2. 分析范围

### 2.1 Claude Code 对标模块

| 文件 | 对标内容 |
|------|--------|
| `src/skills/bundledSkills.ts` | 内置技能注册机制、`BundledSkillDefinition`、文件解压 |
| `src/skills/loadSkillsDir.ts` | 目录加载、frontmatter 解析、去重、动态发现、条件激活 |
| `src/skills/mcpSkillBuilders.ts` | MCP skill 扩展点 |
| `src/tools/SkillTool/SkillTool.ts` | 模型调用 skill 的工具实现（inline + fork） |
| `src/tools/SkillTool/prompt.ts` | Skill 列表 token 预算管理 |
| `src/skills/bundled/skillify.ts` | 从会话中提炼 skill 的工作流 |
| `src/skills/bundled/verify.ts` | 带参考文件的 built-in skill 示例 |
| `src/skills/bundled/remember.ts` | 内置 skill 条件启用示例 |

### 2.2 agentGui 现有基线

| 组件 | 能力 | 不足 |
|------|------|------|
| `Skill.swift` | directoryName / name / description / path / contentURL | 缺少 whenToUse / allowedTools / model / paths / version 等所有执行控制字段 |
| `SkillService.swift` | 扫描 `~/.claude/skills/`，frontmatter 解析，content cache | 仅读 name/description；缺动态发现、条件激活 |
| `SkillsView.swift` | 全局 enable/disable toggle UI | 无参数、无执行模式选择 |
| system prompt 注入 | 把启用技能全文注入为一次性文本 | 无 token 预算；无 whenToUse 路由；无模型主动调用机制 |

---

## 3. 不建议迁移的设计

以下 Claude Code 设计与 Anthropic 内部产品化特性深度绑定，不适合 agentGui 直接迁移：

- 遥测（`logEvent`）、BigQuery 日志、ANT-only 逻辑分支
- `feature('EXPERIMENTAL_SKILL_SEARCH')` 实验性远程 skill 搜索（依赖 Anthropic AKI/GCS 内部服务）
- `remoteSkillLoader` / canonical remote skills
- Bun compile-time `feature()` 宏

---

## 4. Feature 清单

Feature 按模块（Layer）分组，标注优先级与依赖关系。

---

### Layer A — Skill 模型与加载增强（Skill Model & Loading）

这一层是所有后续 feature 的基础，提升 `SkillManifest` 表达能力和加载覆盖范围。

---

#### S-A1 · 扩展 SkillManifest

**优先级:** P0  
**来源:** `loadSkillsDir.ts` → `parseSkillFrontmatterFields()` + `BundledSkillDefinition`

**做什么:** 把 `Skill.swift` 从五个轻量字段扩展为完整的 skill manifest，使后续所有执行控制特性有数据支撑。

**目标结构:**

```swift
struct Skill: Identifiable, Hashable, Sendable {
    // 基础（已有）
    var id: String { directoryName }
    let directoryName: String
    let name: String                         // display name，frontmatter `name:`
    let description: String
    let path: URL                            // skill 目录
    let contentURL: URL                      // SKILL.md

    // 执行控制（新增）
    let whenToUse: String?                   // `when_to_use:` 路由提示
    let argumentHint: String?                // `argument-hint:` 在 UI 展示
    let argumentNames: [String]              // `arguments:` list
    let allowedTools: [String]               // `allowed-tools:` 工具白名单
    let model: String?                       // `model:` 覆盖模型
    let effort: EffortLevel?                 // `effort:` 覆盖努力等级
    let executionContext: SkillExecutionContext  // `context: inline | fork`
    let agent: String?                       // `agent:` 指定使用的 agent 类型
    let userInvocable: Bool                  // `user-invocable:` 默认 true
    let disableModelInvocation: Bool         // `disable-model-invocation:` 默认 false
    let version: String?                     // `version:`
    let paths: [String]?                     // `paths:` 条件激活模式列表

    // 可加载文件列表（新增）
    let hasReferenceFiles: Bool              // 技能目录内是否有额外参考文件
    let loadedFrom: SkillSource             // user / project / managed / bundled
}

enum SkillExecutionContext: String, Codable, Sendable {
    case inline   // 默认：展开 prompt 到当前 conversation
    case fork     // 以子代理运行（隔离 context）
}

enum SkillSource: String, Codable, Sendable {
    case user       // ~/.claude/skills/
    case project    // .claude/skills/ 及其祖先目录
    case managed    // 管理员下发
    case bundled    // 与 app 一起打包的内置 skill
}

enum EffortLevel: String, Codable, Sendable {
    case low, normal, high
}
```

**修改文件:** `agentGui/Models/Skill.swift`

**接入点:** `SkillService.scanSkills(in:)` 需同步扩展 frontmatter 解析，读取以上所有字段。

**验收标准:**
- 所有新字段可正确从 SKILL.md frontmatter 解析并持久化到 `Skill` 实例。
- 缺失字段退回默认值，不影响加载（向后兼容）。

**依赖:** 无

---

#### S-A2 · 项目级技能目录发现

**优先级:** P0  
**来源:** `loadSkillsDir.ts` → `getSkillDirCommands()` + `getProjectDirsUpToHome()`

**做什么:** 除 `~/.claude/skills/` 之外，还从以下位置扫描技能：

1. 当前工作目录（workspace）下的 `.claude/skills/`
2. 从 workspace root 向上到 HOME 沿途的所有 `.claude/skills/`（与 Claude Code 的 `getProjectDirsUpToHome` 等价）

加载顺序（优先级从高到低）：managed → user → project（深→浅）。

管理员来源（managed）目前 agentGui 可以预留为空，或读取 `~/.claude/managed/.claude/skills/`。

**修改文件:** `agentGui/Services/SkillService.swift`

新增：

```swift
/// 从以下位置按优先级加载技能：
/// 1. managed: ~/.claude/managed/.claude/skills/
/// 2. user:    ~/.claude/skills/
/// 3. project: workspace root 向上到 $HOME 的所有 .claude/skills/
func loadSkills(workspaceURL: URL? = nil) async
```

**接入点:** `SkillService.loadSkills()` 改为接受 `workspaceURL` 参数；在 `SessionListView` / workspace 切换时携带 workspace root 调用。

**验收标准:**
- 在 workspace 下有 `.claude/skills/` 时，那里的 skill 会被发现并在 `availableSkills` 中出现，`loadedFrom == .project`。
- 与 `~/.claude/skills/` 内的同名 skill 不冲突（project 优先，用户次之）。

**依赖:** S-A1

---

#### S-A3 · 动态技能目录发现

**优先级:** P1  
**来源:** `loadSkillsDir.ts` → `discoverSkillDirsForPaths()` + `addSkillDirectories()`

**做什么:** 当 built-in agent 调用文件读写工具后，从被操作的文件路径向上 walk，查找路径中是否存在 `.claude/skills/` 目录（仅检查 cwd 以内的路径）。若发现新目录，立即加载并合并到 `availableSkills`，通知系统刷新 skill 列表。

已发现过的目录缓存在 `Set<URL>` 中，避免重复 stat 系统调用。

**新增文件:** `agentGui/Services/SkillDiscoveryCoordinator.swift`

```swift
actor SkillDiscoveryCoordinator {
    /// 已扫描过的目录集合（缓存 hit/miss 两类）
    private var scannedDirs: Set<URL> = []

    /// 从文件路径列表发现新的 .claude/skills/ 目录
    func discoverSkillDirs(forPaths: [URL], cwd: URL) async -> [URL]

    /// 加载新目录并通知 SkillService 合并
    func addSkillDirectories(_ dirs: [URL]) async
}
```

**接入点:** built-in agent tool executor 在每次文件工具（read_file, write_file, edit_file）执行后，把路径列表传给 `SkillDiscoveryCoordinator`。

**验收标准:**
- 在 workspace 子目录 `subproject/.claude/skills/` 中有 skill，读取该子目录下的文件后，skill 自动出现在 `availableSkills`。
- 重复路径不触发重复加载。

**依赖:** S-A1, S-A2

---

#### S-A4 · 条件激活（Paths Frontmatter）

**优先级:** P1  
**来源:** `loadSkillsDir.ts` → `activateConditionalSkillsForPaths()` + gitignore-style matching

**做什么:** 带 `paths:` frontmatter 的 skill 初始不加入活跃技能列表。当 built-in agent 操作的文件路径与其中某个 glob 模式匹配时，该 skill 自动激活，进入 `activatedSkills`，并在下一轮 system prompt 中出现。

激活后不再取消激活（session 内持久），与 Claude Code 行为一致。

**要新增的 API:**

```swift
// SkillService 新增
/// 检测 filePaths 中是否有能激活的条件技能，返回新激活的技能名称列表
func activateConditionalSkills(forPaths: [URL], cwd: URL) -> [String]
```

**glob 匹配:** 使用与 `.gitignore` 兼容的模式匹配（纯 Swift 实现，不依赖外部 C 库，或使用现有 workspace gitignore 逻辑复用）。

**接入点:** 与 S-A3 在同一工具执行后钩子中触发。

**验收标准:**
- 有 `paths: ["**/*.swift"]` 的 skill，读取任意 `.swift` 文件后自动激活。
- 激活事件在 execution theater 中出现一条可见的系统通知（或 debug log）。

**依赖:** S-A1, S-A2

---

#### S-A5 · Skill 去重（Canonical Path）

**优先级:** P1  
**来源:** `loadSkillsDir.ts` → `getFileIdentity()` + realpath-based deduplication

**做什么:** 不同加载路径（如 symlink 与真实路径）可能加载同一个 SKILL.md。在合并 `availableSkills` 时，通过 `realpath()` 解析每个 `contentURL` 的真实路径，跳过已经出现过的文件。

**修改文件:** `agentGui/Services/SkillService.swift`

在 `loadSkills(workspaceURL:)` 中，合并阶段加入：

```swift
var seenRealPaths: Set<String> = []
// 对每个 skill contentURL 调用 URL.resolvingSymlinksInPath / FileManager.destinationOfSymlink
// 跳过 seenRealPaths 中已有的路径
```

**验收标准:**
- 若 `~/.claude/skills/foo/SKILL.md` 是 `.claude/skills/foo/SKILL.md` 的 symlink，只加载一次，`availableSkills` 中只出现一条。

**依赖:** S-A1

---

### Layer B — Skill 列表展示与 Token 预算

---

#### S-B1 · Skill 列表 Token 预算管理器

**优先级:** P0  
**来源:** `src/tools/SkillTool/prompt.ts` → `formatCommandsWithinBudget()` + `SKILL_BUDGET_CONTEXT_PERCENT = 0.01`

**做什么:** 当前 agentGui 把所有启用技能的全文注入 system prompt，随着技能增多会消耗大量 context。改为：

1. 在 system prompt 的 skill 列表区域，只展示每个 skill 的 `name` + `description`（+ `whenToUse` 拼接），不内联全文。
2. 用配置好的 token 预算（默认 1% context window = 200k × 4 chars × 1% = 8000 chars）控制列表总长度。
3. 当全量描述超出预算时，按优先级（bundled > user > project）截断。
4. 技能全文只在 skill 被主动调用时才注入（通过 `SkillInvocationTool` S-C1）。

**新增文件:** `agentGui/Services/SkillCatalogPromptRenderer.swift`

```swift
struct SkillCatalogPromptRenderer {
    /// 最大允许字符数，基于 context window
    let charBudget: Int

    /// 渲染 skill 列表 prompt segment，输入是当前活跃+候选技能的 [Skill]
    func renderSkillListing(_ skills: [Skill]) -> String
}
```

**接入点:** `ClaudeService` / `BuiltInAgentQueryEngine` 构建 system prompt 时，用 `SkillCatalogPromptRenderer` 替换现有 skill 全文注入。

**验收标准:**
- 50 个 skill 时，skill 区段 token 数不超过 2000（约 8000 chars / 4 chars-per-token）。
- 截断时，bundled 技能描述保留完整，余下技能描述被比例截断。

**依赖:** S-A1

---

#### S-B2 · whenToUse 路由提示注入

**优先级:** P0  
**来源:** `SkillTool/prompt.ts` → `getCommandDescription()` 拼接 `cmd.whenToUse`

**做什么:** 在 skill 列表 prompt 中，将每个技能的 `whenToUse` 拼接到 `description` 后面形成一个完整路由提示，帮助模型决策何时主动调用该 skill。

格式：`- <name>: <description> - <whenToUse>`

**修改文件:** `SkillCatalogPromptRenderer.swift`（S-B1 新增的文件）

**验收标准:**
- 有 `when_to_use: "当用户请求代码审查时"` 的 skill，在系统提示的 skill 列表中能看到该提示文字。

**依赖:** S-B1

---

### Layer C — SkillInvocationTool（核心执行层）

这是最有价值的单项改进。SkillInvocationTool 让模型可以在 agent loop 内以工具调用的形式主动触发 skill，而不是依赖用户手动 /slash 命令。

---

#### S-C1 · SkillInvocationTool（inline 模式）

**优先级:** P0  
**来源:** `src/tools/SkillTool/SkillTool.ts` → `call()` inline 分支

**做什么:** 新增 `skill_invoke` 内置工具，输入：

```swift
struct SkillInvokeInput: Codable {
    var skill: String     // skill 名称（directoryName 或 display name）
    var args: String?     // 可选参数字符串
}
```

当模型调用此工具时：

1. 通过 `SkillService.findSkill(name:)` 查找 skill。
2. 读取 SKILL.md 内容。
3. 执行参数替换（`$ARGUMENTS` → args，后续 S-E1 扩展到 named args）。
4. 将 skill prompt 作为新的 user message 注入当前会话，继续 agent loop。
5. 若 skill 有 `allowedTools`，通过 context modifier 把 tool schema 限制到该集合。
6. 若 skill 有 `model` override，临时切换模型。

**新增文件:** `agentGui/Services/BuiltInTools/SkillInvocationTool.swift`

**接入点:** 注册到 `ToolRegistry`；列入 system prompt 的 "available tools" 部分。

**验收标准:**
- 模型可以发出 `{"type": "tool_use", "name": "skill_invoke", "input": {"skill": "code-review"}}` 并触发 skill 展开。
- Skill 展开后，后续工具调用受 `allowedTools` 约束（若有）。
- Skill 不存在时，工具返回可读的错误消息而非 crash。

**依赖:** S-A1, S-B1

---

#### S-C2 · SkillInvocationTool（fork 模式）

**优先级:** P1  
**来源:** `SkillTool.ts` → `executeForkedSkill()` + `prepareForkedCommandContext()` + `runAgent()`

**做什么:** 当 skill 定义了 `context: fork` 时，`SkillInvocationTool` 不展开 prompt 到当前对话，而是：

1. 创建一个独立的子代理 session（复用 `run_subagent` 路径）。
2. 将 skill prompt 作为该子代理的初始用户消息。
3. 子代理在独立 context 中执行（有自己的 token 预算）。
4. 子代理完成后，将结果文本作为工具结果注入父 agent 的对话。

这对于复杂、自包含的 skill（例如"生成完整测试套件"、"代码评审"）非常有价值：不会污染主 agent 的 context，也有独立的错误边界。

**修改文件:** `agentGui/Services/BuiltInTools/SkillInvocationTool.swift`（扩展 S-C1）

执行路径 fork condition：

```swift
if skill.executionContext == .fork {
    return try await executeForkedSkill(skill, args: args, context: toolContext)
} else {
    return try await executeInlineSkill(skill, args: args, context: toolContext)
}
```

**验收标准:**
- `context: fork` 的 skill 以子代理运行，不在主 agent 的消息列表中展开。
- 子代理结果作为 `[Skill Result]` 附件出现在主 agent 时间线。
- fork 执行失败时，主 agent 收到错误工具结果，不 crash。

**依赖:** S-C1

---

#### S-C3 · Skill 权限系统

**优先级:** P1  
**来源:** `SkillTool.ts` → `checkPermissions()` + `skillHasOnlySafeProperties()`

**做什么:** 不是所有 skill 都可以无授权执行。建立一套轻量权限检查：

1. **安全属性自动放行:** 若 skill 只有 `name`、`description`、`whenToUse`、`argumentHint`、`model`（无 allowedTools、无 hooks、无 fork context），自动放行，无需用户确认。
2. **危险属性需确认:** 若 skill 含 `allowedTools`、`hooks`、`context: fork` 或 `agent`，在首次调用时弹出确认 sheet（显示 skill 名称 + 声明的权限）。
3. **全局规则:** 用户可以在设置中为某 skill 添加 "always allow" / "always deny" 规则，存入 `AppSettings.skillPermissionRules`。

**新增文件:** `agentGui/Services/SkillPermissionChecker.swift`

```swift
struct SkillPermissionChecker {
    func checkPermission(for skill: Skill) -> SkillPermissionDecision
}

enum SkillPermissionDecision {
    case autoAllow
    case requireConfirmation(reason: String)
    case deny(reason: String)
}
```

**接入点:** `SkillInvocationTool.call()` 在执行前调用。

**验收标准:**
- 无 allowedTools 的纯提示词 skill 可以直接执行，不弹窗。
- 有 `allowed-tools: [Bash]` 的 skill 在首次调用时弹出确认提示。
- 用户选择 "always allow" 后，后续调用不再弹窗。

**依赖:** S-C1

---

#### S-C4 · allowedTools 上下文修改器

**优先级:** P0  
**来源:** `SkillTool.ts` → `contextModifier()` 中的 `alwaysAllowRules` 更新

**做什么:** 当 skill 带有 `allowed-tools:` 列表时，在 skill 执行过程中，把 agent 可用的工具 schema 限制到 allowedTools 集合（加上原始已有的 alwaysAllowRules）。skill 执行结束后恢复原有工具集。

例如：`allowed-tools: [Read, Grep, Glob]` 的 skill 在执行期间，模型看不到 Bash、Write 等工具 schema。

**修改文件:** `agentGui/Services/BuiltInTools/SkillInvocationTool.swift`

通过 `ToolExposurePolicy`（F-C6，来自主分析设计文档）或独立的临时工具过滤器实现。

**验收标准:**
- Skill 执行期间，不在 allowedTools 里的工具不出现在 API 请求的 tools 数组中。
- Skill 完成后，tools 恢复完整集合。
- 单元测试验证工具集过滤逻辑。

**依赖:** S-C1

---

#### S-C5 · 模型与努力等级覆盖

**优先级:** P1  
**来源:** `SkillTool.ts` → `contextModifier()` 中的 `mainLoopModel` 和 `effortValue`

**做什么:** Skill 可以在 frontmatter 中声明 `model:` 和 `effort:` 覆盖。在 skill 执行期间（inline/fork 均适用）临时切换对应的模型和努力等级。

例如：`model: claude-haiku-4` 的 skill 在执行期间用 Haiku，结束后恢复。这让轻量 skill（如 ToolBatchSummaryService 需要的摘要类任务）能指定使用更小、更快、更便宜的模型。

**修改文件:** `agentGui/Services/BuiltInTools/SkillInvocationTool.swift`

**验收标准:**
- 定义了 `model: claude-haiku-4` 的 skill，执行期间 API 调用使用 Haiku。
- Skill 完成后恢复原来的 main loop 模型。

**依赖:** S-C1

---

### Layer D — 参数传递与变量替换

---

#### S-D1 · 参数字符串替换（$ARGUMENTS）

**优先级:** P0  
**来源:** `loadSkillsDir.ts` → `substituteArguments()` + `${ARGUMENTS}` 替换

**做什么:** 在 skill prompt 文本中，将 `$ARGUMENTS` 或 `${ARGUMENTS}` 替换为 `SkillInvocationTool` 传入的 `args` 字符串。若 args 为空，替换为空字符串。

**修改文件:** `agentGui/Services/SkillService.swift`  
新增 `readSkillContent(name:args:)` 或在 `SkillInvocationTool` 执行前完成替换。

**验收标准:**
- SKILL.md 中含 `Review PR $ARGUMENTS`，传入 args = "123"，执行时 prompt 变为 `Review PR 123`。

**依赖:** S-C1

---

#### S-D2 · 命名参数替换（Named Arguments）

**优先级:** P1  
**来源:** `loadSkillsDir.ts` → `parseArgumentNames()` + `substituteArguments()` 命名变量

**做什么:** Skill frontmatter 支持声明命名参数：

```yaml
arguments:
  - branch
  - ticket
```

Skill 内容中使用 `$branch`、`$ticket` 作为占位符。`SkillInvocationTool` 的 args 字符串按位置或 key=value 格式解析并替换。

args 解析格式：
- 按顺序：第一个词 → branch，第二个词 → ticket  
- 或 key=value：`branch=main ticket=PROJ-123`

**新增文件:** `agentGui/Services/SkillArgumentSubstitution.swift`

```swift
struct SkillArgumentSubstitution {
    func substitute(in content: String, args: String, argumentNames: [String]) -> String
}
```

**验收标准:**
- `arguments: [branch, ticket]` 的 skill，传入 args = "main PROJ-123"，`$branch` → "main"，`$ticket` → "PROJ-123"。

**依赖:** S-D1

---

#### S-D3 · 内置变量替换

**优先级:** P1  
**来源:** `loadSkillsDir.ts` → `${CLAUDE_SKILL_DIR}` 和 `${CLAUDE_SESSION_ID}` 替换

**做什么:** 在 skill prompt 中自动替换以下内置变量：

| 变量 | 值 |
|-----|---|
| `${CLAUDE_SKILL_DIR}` | skill 目录的绝对路径 |
| `${CLAUDE_SESSION_ID}` | 当前 session UUID |

这让 skill 可以用相对方式引用自己目录下的脚本或辅助文件（例如 `cd ${CLAUDE_SKILL_DIR} && bash helpers/setup.sh`）。

**修改文件:** `SkillArgumentSubstitution.swift` 或 `SkillService.readSkillContent()`

**验收标准:**
- SKILL.md 中含 `${CLAUDE_SKILL_DIR}/scripts/run.sh`，执行时被替换为真实绝对路径。

**依赖:** S-D1

---

### Layer E — 参考文件与内容丰富化

---

#### S-E1 · 技能目录前置注入（Base Directory Context）

**优先级:** P0  
**来源:** `loadSkillsDir.ts` → `createSkillCommand().getPromptForCommand()` 中 `Base directory for this skill: ${baseDir}\n\n` 前置

**做什么:** agentGui 的 `SkillService.resolveSkillPaths(in:skillDirectory:)` 已经做了绝对路径改写，但缺少 base directory header。

在每次读取 skill 内容时，在开头自动前置一行：

```
<!-- skill_directory: /Users/feint/.claude/skills/code-review -->
```

（agentGui 已在 v1 有此逻辑，确认其仍然正确工作并保留。）

**验收标准:**
- skill 内容开头存在 `<!-- skill_directory: ... -->` 行，Claude 可以用它定位技能目录。

**依赖:** 无（已有实现，验证即可）

---

#### S-E2 · Skill 参考文件懒加载（Files Extraction）

**优先级:** P1  
**来源:** `bundledSkills.ts` → `extractBundledSkillFiles()` + `SAFE_WRITE_FLAGS` + `O_NOFOLLOW|O_EXCL`

**做什么:** Skill 目录内、SKILL.md 之外可能有其他参考文件（如 schemas、示例、脚本）。当 agent 在 skill 执行时需要读取这些文件，它应该能通过路径直接访问。

当前实现（path rewriting）已经部分解决了这个问题：绝对-looking 路径会被重写为 skill 目录内的真实路径。

本 feature 补充：

1. 在 `SkillService.hasReferenceFiles(skill:)` 中扫描 skill 目录是否有 SKILL.md 以外的文件。
2. 更新 `Skill.hasReferenceFiles` 字段为 true。
3. `SkillCatalogPromptRenderer` 在 listing 中标注此 skill 有附加文件可读。

这是一个 light enhancement，不需要实现 bundledSkills.ts 那样的二进制打包解压（agentGui 的技能都是磁盘文件，agent 直接读取即可）。

**修改文件:** `agentGui/Services/SkillService.swift`

**验收标准:**
- 有多个文件的 skill 目录，`hasReferenceFiles = true`。
- `SkillInvocationTool` 执行该 skill 时，补充 `Base directory` 提示，agent 通过 `read_file` 读取附属文件时能成功。

**依赖:** S-A1

---

### Layer F — 内置技能系统（Built-in Skills）

---

#### S-F1 · 内置技能注册表

**优先级:** P0  
**来源:** `bundledSkills.ts` → `registerBundledSkill()` + `getBundledSkills()`

**做什么:** 建立 agentGui 的内置技能注册机制，允许 Swift 代码在启动时注册内置技能（不依赖磁盘文件）。内置技能：

- `loadedFrom = .bundled`
- 始终列在 skill 列表中（不受用户启用开关控制，但可以设置 `isEnabled` 谓词）
- 不被去重逻辑删除
- 在 SkillTool listing 的 token 预算分配中优先保留完整描述

**新增文件:** `agentGui/Services/BuiltInSkillRegistry.swift`

```swift
/// 内置技能定义（不依赖磁盘文件）
struct BuiltInSkillDefinition {
    let name: String
    let description: String
    let whenToUse: String?
    let argumentHint: String?
    let allowedTools: [String]
    let model: String?
    let userInvocable: Bool
    let isEnabled: (() -> Bool)?
    let executionContext: SkillExecutionContext
    let getPromptContent: (String?) async -> String    // args → prompt
}

final class BuiltInSkillRegistry {
    static let shared = BuiltInSkillRegistry()
    func register(_ definition: BuiltInSkillDefinition)
    func allSkills() -> [Skill]
}
```

**接入点:** `SkillService.loadSkills()` 把 `BuiltInSkillRegistry.shared.allSkills()` 合并进 `availableSkills`。

**验收标准:**
- 注册的内置 skill 出现在 `availableSkills`，`loadedFrom == .bundled`。
- 不受用户启用开关控制（直接可用）。

**依赖:** S-A1

---

#### S-F2 · Skillify 内置技能

**优先级:** P1  
**来源:** `src/skills/bundled/skillify.ts` → `registerSkillifySkill()`

**做什么:** 把 Claude Code 的 `skillify` 工作流迁移为 agentGui 内置技能，让 built-in agent 在会话结束时能将本次成功流程自动写成 SKILL.md 文件，沉淀为可复用的本地技能。

工作流简化版（去除 ANT-only 部分和 Slack/SessionMemory 依赖）：

1. 从当前会话消息中提取用户消息列表（"What did the user ask and correct?")。
2. 通过多轮 `ask_user_question` 工具与用户确认技能名称、描述、应用范围（repo / user level）。
3. 生成 SKILL.md frontmatter + 步骤 prompt。
4. 写入 `.claude/skills/<name>/SKILL.md`（项目级）或 `~/.claude/skills/<name>/SKILL.md`（用户级）。
5. 通知 `SkillService` 刷新。

**新增文件:** `agentGui/Services/BuiltInSkills/SkillifySkill.swift`

```swift
func registerSkillifySkill() {
    BuiltInSkillRegistry.shared.register(BuiltInSkillDefinition(
        name: "skillify",
        description: "将当前会话的可复现流程提炼为 SKILL.md，存入本地技能库。",
        whenToUse: "当用户说"把这次过程保存为技能"、"记住这个工作流"时使用。",
        allowedTools: ["read_file", "write_file", "ask_user_question", "create_directory"],
        executionContext: .inline,
        getPromptContent: { args in skillifyPrompt(args) }
    ))
}
```

**验收标准:**
- 用户说"把这次过程保存为技能"，agent 调用 `skill_invoke skillify`，通过多轮问答生成 SKILL.md 并写入磁盘。
- 写入完成后 `availableSkills` 自动增加该 skill。

**依赖:** S-F1, S-C1

---

#### S-F3 · Verify 内置技能

**优先级:** P2  
**来源:** `src/skills/bundled/verify.ts` + Claude Code verify SKILL.md

**做什么:** 内置一个"verify"技能，当用户要求验证某功能是否正常时自动激活。提示模型按照以下顺序执行：

1. 构建 / 编译项目（`xcodebuild build` 或根据检测到的语言调整）。
2. 运行相关测试。
3. 手动测试（用 `ask_user_question` 向用户确认关键交互）。
4. 报告 pass/fail 结果。

与工具治理层的 `VerificationEvidenceHook`（F-C4）协同：verify skill 产出的 test output 会被 hook 自动提炼成 `VerificationEvidence`。

**新增文件:** `agentGui/Services/BuiltInSkills/VerifySkill.swift`

**验收标准:**
- 调用 `skill_invoke verify` 后，agent 依次执行 build + test，并在 execution theater 中展示验证结果摘要。

**依赖:** S-F1, S-C1

---

### Layer G — Skill 创作工具与 UI

---

#### S-G1 · SkillsView 增强（展示 manifest 信息）

**优先级:** P1  
**来源:** agentGui 现有 `SkillsView.swift` + S-A1 扩展的 Skill 模型

**做什么:** 更新 `SkillsView` 展示以下新增信息：

- `whenToUse` 文本（可折叠，副标题样式）
- `argumentHint`（如果有，在 skill 名称旁展示 "接受参数" 标签）
- `version` 徽章
- `loadedFrom` 来源标签（user / project / bundled，不同颜色区分）
- `executionContext` 标签（inline / fork）
- 条件激活状态（active / conditional/inactive）

**修改文件:** `agentGui/Views/Skills/SkillsView.swift`

**验收标准:**
- SkillsView 能准确展示所有新字段，条件激活的 skill 有视觉区分。

**依赖:** S-A1

---

#### S-G2 · Skill 版本显示与冲突检测

**优先级:** P2  
**来源:** `loadSkillsDir.ts` → `version` frontmatter 字段

**做什么:** 当 user skill 和 project skill 有同名时，显示警告（"project skill shadowing user skill"）并在 SkillsView 中标注哪个生效。

version 字段目前只用于 UI 展示，不做自动升级或兼容性检查。

**修改文件:** `agentGui/Views/Skills/SkillsView.swift`

**验收标准:**
- 同名 skill 在不同来源存在时，SkillsView 中展示遮盖提示，标注实际生效的来源。

**依赖:** S-A1, S-A2

---

## 5. 不依赖迁移的现有能力校验

以下 agentGui 已有能力无需重新实现，但需要在 S-A1 扩展后验证其仍正确工作：

| 现有能力 | 对应代码 | 验证点 |
|---------|--------|--------|
| Skill 路径绝对化 + base directory header | `SkillService.resolveSkillPaths()` | S-E1 验收 |
| Skill frontmatter 解析 (name/desc) | `SkillService.parseFrontmatter()` | S-A1 扩展后向后兼容 |
| 内容 cache | `SkillService.contentCache` | 多次 `readSkillContent` 不重复读盘 |
| 全局 enable/disable | `AppSettings.enabledSkillNames` | 仍然对 user/project skill 生效；bundled skill 不受此控制 |

---

## 6. Feature 优先级汇总

| Feature | 名称 | 优先级 | 依赖 |
|---------|------|--------|------|
| S-A1 | 扩展 SkillManifest | P0 | — |
| S-A2 | 项目级技能目录发现 | P0 | S-A1 |
| S-B1 | Skill 列表 Token 预算管理器 | P0 | S-A1 |
| S-B2 | whenToUse 路由提示注入 | P0 | S-B1 |
| S-C1 | SkillInvocationTool（inline 模式）| P0 | S-A1, S-B1 |
| S-C4 | allowedTools 上下文修改器 | P0 | S-C1 |
| S-D1 | 参数字符串替换（$ARGUMENTS）| P0 | S-C1 |
| S-E1 | 技能目录前置注入（验证现有）| P0 | — |
| S-F1 | 内置技能注册表 | P0 | S-A1 |
| S-A3 | 动态技能目录发现 | P1 | S-A1, S-A2 |
| S-A4 | 条件激活（paths frontmatter）| P1 | S-A1, S-A2 |
| S-A5 | Skill 去重（Canonical Path）| P1 | S-A1 |
| S-C2 | SkillInvocationTool（fork 模式）| P1 | S-C1 |
| S-C3 | Skill 权限系统 | P1 | S-C1 |
| S-C5 | 模型与努力等级覆盖 | P1 | S-C1 |
| S-D2 | 命名参数替换 | P1 | S-D1 |
| S-D3 | 内置变量替换 | P1 | S-D1 |
| S-E2 | Skill 参考文件懒加载 | P1 | S-A1 |
| S-F2 | Skillify 内置技能 | P1 | S-F1, S-C1 |
| S-G1 | SkillsView 增强 | P1 | S-A1 |
| S-F3 | Verify 内置技能 | P2 | S-F1, S-C1 |
| S-G2 | Skill 版本显示与冲突检测 | P2 | S-A1, S-A2 |

---

## 7. 新增文件目录结构

```text
agentGui/
  Models/
    Skill.swift                              ← 扩展 (S-A1)
  Services/
    SkillService.swift                       ← 扩展 (S-A2, S-A4, S-A5)
    SkillCatalogPromptRenderer.swift         ← 新增 (S-B1, S-B2)
    SkillArgumentSubstitution.swift          ← 新增 (S-D1, S-D2, S-D3)
    SkillDiscoveryCoordinator.swift          ← 新增 (S-A3)
    SkillPermissionChecker.swift             ← 新增 (S-C3)
    BuiltInSkillRegistry.swift               ← 新增 (S-F1)
    BuiltInTools/
      SkillInvocationTool.swift              ← 新增 (S-C1, S-C2, S-C4, S-C5)
    BuiltInSkills/
      SkillifySkill.swift                    ← 新增 (S-F2)
      VerifySkill.swift                      ← 新增 (S-F3)
  Views/
    Skills/
      SkillsView.swift                       ← 扩展 (S-G1, S-G2)
```

---

## 8. 最终判断

Claude Code 的 skill 系统最值得落地到 agentGui 的，不只是"多了几个字段"，而是以下三个结构性升级：

1. **让模型有主动权**（S-C1 + S-B2）：模型凭 `whenToUse` 路由提示主动决定何时调用 skill，而不是等用户手动 `/slash`。这是把 skill 从"用户指令"升级为"模型能力"的关键。

2. **执行上下文隔离**（S-C2 fork + S-C4 allowedTools）：skill 不再是一次性 prompt 注入，而是有自己的 tool 白名单、model 覆盖、token 预算。复杂 skill 在子代理中安全运行，不干扰主 agent context。

3. **知识可积累闭环**（S-F2 skillify）：built-in agent 完成任务后可以把成功流程提炼成 skill 文件。用的越多，本地技能库越丰富，agent 越能复用历史经验。

对 agentGui 最正确的路线是：先落 P0（9 个 Feature，Skill 扩展 + SkillInvocationTool + 内置注册表），再落 P1（12 个 Feature，动态发现 + fork + skillify），最后落 P2（2 个 Feature，版本管理与 verify skill）。
