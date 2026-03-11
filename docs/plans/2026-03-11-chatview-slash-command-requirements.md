# ChatView Slash Command 需求文档

**目标：** 为 ChatView 输入区增加类似主流 agent 产品的 `/` 命令入口，让用户可以在发送前显式指定本轮对话应启用的 skill；同时在架构层面避免把 `/` 命令硬编码为“只支持 skill”，为后续扩展到 agent、workflow、模板、上下文动作等其他命令类型预留统一模型。

**结论：** 推荐采用“通用 Slash Command Catalog + 每轮输入指令 Input Directives”的方案。`/` 只是输入触发器，不直接等价于 skill。v1 先接入 skill provider，但 ChatView、输入状态、提交载荷、后端请求拼装都按通用命令模型设计。

---

## 1. 背景与现状

当前 Chat 输入区位于 `agentGui/Views/ChatView+InputArea.swift`，已经具备三类输入辅助能力：

- 文本输入与发送
- `@` 文件 mention 补全
- 文件拖拽与上下文 chip

当前 skill 能力已经具备基础设施，但触发方式仍偏“被动”：

- `SkillService` 可以扫描本地安装的 skill，并读取 `SKILL.md`
- `AppSettings.enabledSkillNames` 维护全局启用的 skill 列表
- `ACPClientService` 会把启用 skill 注入 system prompt，并暴露 `read_skill` tool

因此，现状的问题不是“没有 skill 系统”，而是“缺少用户显式指定本轮 skill 的输入机制”。这会带来三个问题：

- 用户无法像主流 agent 产品一样，通过 `/` 直接选择能力模式
- skill 是否生效依赖模型自行判断是否调用 `read_skill`，确定性不足
- 后续若要支持 `/agent`、`/workflow`、`/memory`、`/template` 等，会被迫继续堆叠临时逻辑

## 2. 产品目标

### 2.1 核心目标

- 在 ChatView 输入框中输入 `/` 时弹出命令选择面板
- 用户可通过键盘或鼠标快速筛选并选中一个 skill
- 被选中的命令在发送前形成“本轮输入指令”，而不是只作为普通文本残留在输入框中
- 本轮请求必须稳定感知到该 skill，不依赖模型是否“想起来”调用 `read_skill`
- 命令模型必须可扩展，后续新增命令类型时不需要重写 Chat 输入架构

### 2.2 非目标

- 本期不改造 skill 文件格式
- 本期不重做设置页 Skills 管理页
- 本期不要求一次支持多种命令类型落地，只要求架构可扩展
- 本期不要求实现所有主流产品的高级命令能力，如多命令串联、命令参数表单、命令历史推荐

## 3. 用户故事

### 3.1 v1 必须支持

1. 作为用户，我输入 `/` 后，希望立即看到可选 skill 列表，而不是自己记名字。
2. 作为用户，我输入 `/brain` 之类前缀后，希望列表能实时过滤。
3. 作为用户，我希望用上下方向键切换候选项，按 `Enter` 或 `Tab` 选中，按 `Esc` 关闭。
4. 作为用户，我选中某个 skill 后，希望输入区出现明确的“已激活 skill”视觉反馈。
5. 作为用户，我发送消息后，希望系统按我指定的 skill 执行，而不是让模型自由决定是否启用。
6. 作为用户，我希望这次选择默认只影响当前消息，不悄悄改写全局设置。

### 3.2 v1 应该支持

1. 对已安装但未全局启用的 skill，也能通过 `/` 在当前轮次临时启用。
2. 列表中能区分“全局已启用”和“仅本轮临时可用”的 skill 状态。
3. 发送后保留一份可审计的记录，便于后续在消息详情或工具轨迹中解释“本轮为何触发该 skill”。

### 3.3 后续版本预留

1. `/agent` 选择代理角色
2. `/workflow` 启动工作流
3. `/preset` 选择提示词模板
4. `/context` 注入固定上下文动作
5. `/memory` 调用记忆相关快捷能力

## 4. 方案对比

### 方案 A：把 `/skill-name` 当成普通文本发送

做法：用户输入 `/brainstorming`，原样保留在消息里，让模型自行理解。

优点：

- 实现最简单
- 几乎不需要改后端请求结构

缺点：

- 可靠性低，模型可能忽略或误解
- 无法与后续其他命令类型形成统一协议
- 无法稳定审计“命令是否被执行”

结论：不推荐。

### 方案 B：Slash 选择生成结构化输入指令，并在发送前自动解析

做法：`/` 只负责选择命令项；选中后生成结构化 `InputDirective`，提交请求时由客户端把该指令解析为实际能力激活。对于 skill，客户端应在发请求前直接把 skill 内容解析进“显式激活上下文”，而不是等待模型再调用 `read_skill`。

优点：

- 用户意图表达明确，执行更确定
- 命令 UI 与后端能力解耦，利于扩展
- 能记录“选择了什么命令、如何生效”

缺点：

- 需要新增输入状态模型和请求拼装层
- 比纯文本方案复杂

结论：推荐采用。

### 方案 C：Slash 选择直接改写全局设置

做法：用户选中 skill 后，自动写入 `AppSettings.enabledSkillNames`。

优点：

- 后端兼容成本低

缺点：

- 用户一次性操作污染长期配置
- 无法表达“仅当前轮次生效”
- 不适合未来 `/workflow`、`/agent` 等短生命周期命令

结论：不推荐。

## 5. 推荐方案

采用方案 B，并分两层设计：

### 5.1 UI 层：通用 Slash Command Catalog

ChatView 不直接依赖 `Skill`，而是依赖统一的命令项模型，例如：

- `SlashCommandItem`
- `SlashCommandKind`
- `SlashCommandProvider`

`SkillService` 只是第一个 provider，把本地 skill 转成可展示、可筛选、可选中的 slash item。

### 5.2 提交层：Input Directives

用户选中 slash 项后，不建议只把 `/brainstorming` 作为明文文本保留在输入框里。推荐转换成“输入指令”状态，例如：

- `ChatInputDirective(kind: .skill, payload: ...)`

发送时，提交载荷应拆成两部分：

- `visibleText`：用户真正要说的话
- `directives`：当前轮次附加的命令化意图

这样未来即便支持 `/workflow`、`/agent`，也只是在 `directives` 中增加新的解析分支，而不需要再次改写输入区底层模型。

## 6. 功能需求

### 6.1 触发规则

- 当光标所在 token 以 `/` 开头时，显示 slash 面板
- 如果输入框为空，输入第一个 `/` 应立即弹出面板
- 若 `/` 前面是空白、换行或消息开头，视为命令触发
- 若 `/` 出现在普通路径、URL、代码片段中，不应误触发

建议复用当前 mention 检测思路，但不要把 `/` 逻辑硬塞进 mention 分支；应抽象为“输入触发器识别器”。

### 6.2 候选列表

v1 列表数据源来自本地已安装 skill，按以下顺序展示：

- 全局已启用 skill
- 已安装但未全局启用 skill

每个候选项至少展示：

- 名称
- 简短描述
- 类型图标或标签，例如 `Skill`
- 状态标签，例如“已启用”或“仅本轮”

筛选匹配维度：

- `name`
- `directoryName`
- `description`

### 6.3 选择交互

- `Up` / `Down`：切换高亮项
- `Enter`：当面板打开且有高亮项时，优先选中命令；仅在没有候选时执行普通换行或发送逻辑
- `Tab`：选中当前项
- `Esc`：关闭面板
- 鼠标点击：选中当前项

### 6.4 选中后的表现

选中 skill 后，推荐不要把整段 `/skill-name` 继续留在原始文本中，而是转成输入区顶部或编辑器前方的 directive chip，例如：

- `Skill: brainstorming`

用户可以：

- 继续输入正文
- 点击 `x` 移除该指令
- 再次输入 `/` 更换命令

### 6.5 发送行为

- v1 只允许一个激活中的 slash directive
- 若已选择 skill，发送时应把该 skill 作为“本轮显式激活项”加入请求
- 该激活不应默认写回 `AppSettings.enabledSkillNames`
- 发送完成后，是否清空该 directive 采用“默认清空”策略，避免误作用到下一轮

### 6.6 空态与异常

- 无命令匹配时，列表显示空态文案，而不是静默消失
- 若 skill 内容读取失败，发送前就应在客户端报错并提示，而不是把失败推给模型
- 若用户选中了当前系统不可用的命令项，应阻止发送并给出原因

## 7. 技术设计

### 7.1 建议的数据模型

建议新增统一模型，而不是在 ChatView 中直接塞 `Skill`：

```swift
enum SlashCommandKind {
    case skill
    case agent
    case workflow
    case preset
    case contextAction
}

struct SlashCommandItem: Identifiable, Hashable {
    let id: String
    let kind: SlashCommandKind
    let title: String
    let subtitle: String
    let aliases: [String]
    let badge: String?
    let isEnabledByDefault: Bool
    let payload: SlashCommandPayload
}

enum ChatInputDirective: Identifiable, Hashable {
    case slashCommand(SlashDirective)
}
```

其中：

- `SlashCommandItem` 面向 UI 展示与筛选
- `ChatInputDirective` 面向“本轮提交意图”
- `payload` 面向执行层解析

这三层不要混用。否则未来一旦出现非 skill 命令，ChatView 会很快失控。

### 7.2 Provider 机制

建议引入 provider 协议：

```swift
protocol SlashCommandProvider {
    func items(context: SlashCommandContext) -> [SlashCommandItem]
}
```

v1 实现：

- `SkillSlashCommandProvider`

后续可扩展：

- `WorkflowSlashCommandProvider`
- `AgentSlashCommandProvider`
- `PromptPresetSlashCommandProvider`

这样 ChatView 只消费一个 catalog，不关心具体命令来自哪里。

### 7.3 输入状态

建议在 ChatView 中新增独立状态，而不是复用 mention 状态字段：

- `slashQuery`
- `slashCandidates`
- `highlightedSlashItemID`
- `activeInputDirectives`

如果后续计划统一 mention 与 slash 的面板渲染，可进一步抽象：

- `ComposerAssistSession`
- `ComposerAssistTriggerKind`
- `ComposerAssistCandidate`

但 v1 不要求把 mention 全量重构为同一体系，只要求 slash 设计不要阻断未来统一。

### 7.4 请求拼装

这是本需求最关键的部分。

当前请求构建依赖：

- 全局启用的 `enabledSkills`
- system prompt 中的 skill 列表
- 运行时 `read_skill` tool

为了让 `/skill` 具备“显式指定”的确定性，推荐新增“本轮显式激活 skill”合并逻辑：

1. 全局启用的 skill 继续作为基础技能集
2. 若本轮 directive 指定某个 skill，则把该 skill 加入本轮有效 skill 集，即使它未写入全局设置
3. 在发请求前，客户端直接读取该 skill 的内容，并把它注入到本轮请求的显式上下文中
4. 模型仍可保留 `read_skill` tool，但 slash 选中的 skill 不应再依赖模型二次发现

推荐增加一段显式上下文，例如：

- `## Explicitly Activated Skills For This Turn`

其中包含：

- skill 名称
- 激活来源：user slash command
- 已解析的 skill 内容摘要或全文

这样能保证 slash 行为具备可解释性和可审计性。

### 7.5 审计与展示

建议为本轮消息保留一份“输入指令快照”，至少满足：

- 消息详情中能看到本轮是否显式选择了 skill
- 后续如果要解释“为什么会出现某个执行风格”，可以追溯到 slash 选择

v1 可以只保留在内存消息构建链路里；更完整的版本可落到消息 metadata 或 tool call presentation 中。

## 8. UI 细节要求

### 8.1 面板样式

- 沿用当前 mention popup 的轻量卡片风格，避免引入完全不同的视觉组件
- 列表上限建议 6 到 8 项
- 当前高亮项需要明显，但不要压过输入区正文

### 8.2 指令 chip

- 选中后以 chip 形式展示在输入区正文上方，和文件 chip、上下文 chip 视觉体系保持一致
- chip 上明确显示命令类型，例如 `Skill`
- 允许删除

### 8.3 键盘优先

该功能必须以键盘流为第一优先级，因为 `/` 命令的价值就在于减少鼠标切换。

最低要求：

- 输入 `/`
- 键盘筛选
- 回车确认
- 继续输入正文
- `Cmd+Enter` 发送

整个流程中不应强迫用户切换到鼠标。

## 9. 兼容性与边界

### 9.1 与现有 mention 的关系

- `@` mention 继续用于文件引用
- `/` slash 只用于命令激活
- 二者都属于输入辅助，但语义不同
- 允许同一条消息同时包含文件 mention 和一个 slash directive

### 9.2 与全局 Skills 设置页的关系

- 设置页仍负责“长期默认启用”
- slash 负责“本轮临时显式指定”
- 二者不是替代关系，而是默认能力与临时能力的分层

### 9.3 多命令问题

为控制复杂度，v1 建议只允许一个 slash directive 生效。原因：

- 避免 skill + workflow + agent 的优先级冲突
- 降低请求拼装复杂度
- 更符合首版认知负担控制

但底层 `directives` 数据模型仍应支持未来多项并存。

## 10. 验收标准

### 10.1 功能验收

- 输入 `/` 可弹出 slash 命令面板
- 列表能显示本地 skill 候选
- 关键字过滤生效
- 键盘上下选择、回车确认、Esc 关闭全部可用
- 选中后生成可见 directive chip
- 发送后当前轮次请求能稳定包含被选 skill
- 未全局启用的 skill 可被本轮临时激活
- 本轮激活不会污染全局设置

### 10.2 体验验收

- 从输入 `/` 到完成选择，不超过一次额外点击
- 面板打开和关闭无明显闪烁
- 与 `@` mention、文件附件、上下文 chip 不互相遮挡或打架

### 10.3 技术验收

- ChatView 不直接把 slash 逻辑写死到 `Skill` 类型上
- 新增命令类型时，不需要重写输入区主流程
- 请求拼装层能区分“全局默认 skill”和“本轮显式激活 skill”

## 11. 建议的实现落点

建议影响面如下：

- `agentGui/Views/ChatView.swift`
  负责增加 slash 相关输入状态
- `agentGui/Views/ChatView+InputArea.swift`
  负责 slash 检测、列表展示、directive chip 展示、键盘选择行为
- `agentGui/Models/Skill.swift`
  无需直接修改，但会作为 skill provider 的输入来源
- `agentGui/Services/SkillService.swift`
  提供 slash skill 列表所需的数据读取能力
- `agentGui/Services/ACPClientService.swift`
  负责把“本轮显式激活 skill”并入请求构建
- 新增建议：`SlashCommandItem`、`SlashCommandProvider`、`ChatInputDirective` 相关模型与服务文件

## 12. 分阶段建议

### Phase 1：可用版本

- `/` 弹出 skill 列表
- 支持筛选、键盘选择、chip 展示
- 支持本轮临时激活 skill
- 发送时把显式 skill 合并进请求

### Phase 2：架构巩固

- 抽象通用 provider registry
- 补充消息级指令快照
- 统一命令与 mention 的输入辅助基础设施

### Phase 3：扩展命令类型

- `workflow`
- `agent`
- `preset`
- `contextAction`

## 13. 最终建议

这项需求不应被实现为“在输入框里加一个 skill 下拉框”，而应被定义为“为 Chat composer 引入通用命令层”。

v1 的用户价值来自 skill 显式指定，但真正决定后续可扩展性的，是下面两点是否从第一天就设计正确：

- `/` 命令先抽象为统一 `SlashCommandItem`，而不是直接等于 `Skill`
- 发送链路先抽象为 `InputDirectives`，而不是把 `/brainstorming` 当成普通文本碰碰运气

如果这两点做对，后续扩展非 skill 命令时只是在 catalog 和 directive resolver 上增量加能力；如果这两点做错，未来每加一种命令类型，Chat 输入区和请求构建层都要再被重拆一次。