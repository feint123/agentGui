日期：2026-03-21

# Agent 文件变更最终确认与 Diff 审查技术设计

## 1. 背景与结论

当前主流 agent 产品在“改文件”这件事上，逐渐收敛到了几个共同模式：

1. agent 可以自主生成或收集改动。
2. 用户能在最终落盘前看到 diff。
3. 用户可以在 apply 前停止、丢弃、回退或重定向。
4. 系统会保留日志、证据和可审计轨迹，而不是只给出一句“已修改”。

对本项目而言，问题并不是“缺一个 diff 页面”，而是当前系统还没有一个独立的“变更提案审查层”。

仓库里其实已经有三块重要基础：

1. `ToolCall.diffContent` 已能承载单次工具调用的 patch 摘要。
2. `GitDiffView` 已能渲染统一 diff。
3. 新的 conversation execution runtime 已经把“执行”从 UI 中抽离为更清晰的作业系统。

但仍有两个结构性缺口：

1. 内建文本编辑路径仍然会直接写真实工作区文件。
2. 外部 ACP / CLI agent 的文件改动还没有被统一收敛到“先审查、后 apply”的提交流程。

因此，推荐方案不是继续在 `ToolCall` 上追加状态字段，而是新增一套独立、模块化的 **Change Review Pipeline**：

1. agent 的所有文件改动先进入隔离工作区或提案缓冲层。
2. 系统持续计算 live diff，并将其持久化为 `ChangeProposal`。
3. 用户在专用 review UI 中执行 `Apply`、`Apply Selected`、`Discard`、`Revert Before Apply`。
4. 只有在最终确认后，`ApplyEngine` 才把改动落到真实工作区。

这是一个“先收集变更，再审核，再提交”的架构，而不是“先改文件，再补一个撤销按钮”的架构。

## 2. 设计目标与非目标

### 2.1 目标

本方案必须满足以下目标：

1. 所有 agent 文件改动都存在最终确认入口。
2. 用户在 apply 前可以查看完整 diff，并执行整批或局部回退。
3. 方案必须同时兼容：
   - 内建工具调用路径
   - GitHub Copilot CLI / OpenCode 这类外部 agent 路径
   - 后续新增 provider
4. 改动必须具备持久化和恢复能力，应用重启后不能丢失待审查提案。
5. UI 与执行系统解耦，变更审查不应回退为 `ClaudeService` 内部布尔状态。
6. 需要保留审计信息，包括提案来源、涉及文件、风险等级、用户决策与 apply 结果。
7. 方案要优先复用现有 `GitDiffView`、`ToolCall` 展示链路与 execution runtime。

### 2.2 非目标

当前阶段明确不做以下内容：

1. 不做 CRDT / OT 多人实时协作编辑。
2. 不要求第一阶段就支持语义级 diff 或 AST 级 merge。
3. 不要求第一阶段支持二进制文件的精细化 patch 预览。
4. 不要求第一阶段实现任意 hunk 级别编辑器内修改；文件级审查即可先落地。
5. 不把“待审查变更”混入 `ExecutionJobState`，避免执行状态与工作区状态耦合。

## 3. 调研结论

### 3.1 主流产品与官方手册

本次调研重点参考了四类产品形态：Cursor、GitHub Copilot coding agent、Claude Code、Codex。

#### A. Cursor 的核心模式

Cursor 官方文档强调：

1. agent 工作时，diff 视图实时展示变更。
2. 如果发现方向偏了，用户可以中途 `Stop`。
3. 如需彻底重来，建议先撤销改动，再补计划重新执行。
4. 云端 agent 的产物最终以分支 / PR 形式交付，用户在合并前审查。

这说明 Cursor 把“live diff + 中途打断 + 最终人工审查”当作默认工程流程，而不是高级功能。

#### B. GitHub Copilot coding agent 的核心模式

GitHub 官方文档强调：

1. 可以并发管理多个 agent session。
2. 用户可以查看 live session log。
3. 用户可以在 session 中途追加 steering 输入。
4. 完成后通过 PR 审查、继续修改或合并。

其核心不是“agent 直接改主工作区”，而是“agent 生成可审查结果，用户在 review/merge 环节拥有最终控制权”。

#### C. Claude Code 的核心模式

Claude Code 官方安全文档与设置文档显示：

1. 默认是严格权限控制与只读优先。
2. 写文件、执行命令等敏感行为需要明确权限。
3. `acceptEdits` 是一种批量接受编辑的模式，但仍保留命令副作用的权限控制。
4. 官方明确要求用户在批准前审查建议的代码与命令。
5. 项目级和组织级权限规则可以收敛为统一策略。

这说明“批量接受编辑”不等于“无审查自动写盘”，而是意味着系统要有明确的审查与批准边界。

#### D. Codex 的核心模式

OpenAI 对 Codex 的官方描述强调：

1. 每个任务在隔离环境中运行。
2. 任务完成后提供终端日志、测试结果、引用证据和 diff。
3. 用户在集成前仍需人工审查和验证。
4. 新一代 Codex 更强调用户在任务中途进行引导和监督。

这表明对复杂 agent 来说，最稳健的模式不是“直接在真实工作区执行写入”，而是“隔离执行 + 证据输出 + 人工集成”。

### 3.2 论文与研究结论

本次方案特别参考了以下研究结论：

1. Amershi 等人在 CHI 2019 的《Guidelines for Human-AI Interaction》提出，AI 系统在出错或不确定时，应支持高效 dismissal、correction、解释原因和全局控制。
2. Barke 等人在《Grounded Copilot》中观察到，程序员与代码生成模型的交互在“加速模式”和“探索模式”之间切换，因此系统需要低摩擦的预览与回退能力，而不是只有最终结果。
3. Perry 等人在《Do Users Write More Insecure Code with AI Assistants?》中发现，使用 AI 助手的参与者更容易写出不安全代码，且更容易高估其安全性。
4. EvalPlus 论文指出，更严格的测试会揭露大量原本被误判为正确的 LLM 生成代码，这直接说明“能编译”或“看起来合理”不够，必须把验证证据纳入决策界面。

结合产品手册与论文，最关键的设计原则是：

1. 不让用户失去最终控制权。
2. 不让 agent 改动在不可见状态下直接进入真实工作区。
3. 审查必须同时展示 diff、来源、解释和验证结果。
4. 停止、丢弃、重定向应该是低成本操作。

## 4. 现状诊断

### 4.1 当前仓库已有能力

当前仓库已经有以下可复用能力：

1. `ToolCall` 模型已经有 `diffContent` 字段，说明系统已经意识到“工具调用结果”需要向 UI 暴露变更摘要。
2. `ToolCallBubbleView` 与 `ToolCallDetailContentView` 已经有细粒度的工具调用展示层。
3. `GitDiffView` 已能解析统一 diff 并在主编辑区展示。
4. `ConversationExecutionOrchestrator` 与 `ExecutionProjectionStore` 已将执行态从 UI 中抽离。

这些基础决定了：

1. 我们不需要再造一套新的 diff 渲染器。
2. 也不应该把变更审查逻辑塞回 provider 或 `ClaudeService` 内部。

### 4.2 当前缺口

真正的缺口有三个：

1. **缺少提案聚合体**
   - 现在 `ToolCall` 更像“单次动作记录”，不是“跨多个工具调用的工作区提案”。
2. **缺少隔离写入边界**
   - 现在内建文本编辑会直接改真实文件；对外部 agent，也没有统一的隔离工作区层。
3. **缺少最终审查状态机**
   - 目前系统有执行中、已完成、权限请求，但没有“收集中”“待审查”“已丢弃”“冲突待处理”这类工作区提案状态。

## 5. 备选路线比较

### 5.1 路线 A：仅扩展 `ToolCall.diffContent`

做法：继续沿用现有工具调用记录，在 `ToolCall` 上增加更多 diff、审批、revert 字段。

优点：

1. 改动面小。
2. UI 接入快。

缺点：

1. 不能自然表达跨多个工具调用的单一提案。
2. 无法解决“真实文件已被改写”的根因。
3. 对外部 agent 几乎只能做事后记录，做不到真正的最终确认前 apply。

结论：不推荐。

### 5.2 路线 B：按 provider 分别做拦截

做法：GitHub Copilot 一套、OpenCode 一套、built-in 一套，各自发明预览与 apply 流程。

优点：

1. 可以较快适配单一 provider。
2. 能利用各 provider 的私有能力。

缺点：

1. 模块边界碎裂。
2. 每接一个 provider 都要复制一套状态机和 UI。
3. 审计、恢复、冲突处理会出现三套行为。

结论：只可作为过渡，不应成为主设计。

### 5.3 路线 C：统一 Change Review Pipeline

做法：新增一套统一的变更提案流水线，所有 provider 通过 adapter 接入，真实工作区只接受最终 `ApplyEngine` 的写入。

优点：

1. 从根因上解决“先写盘后补救”的问题。
2. 同时兼容内建编辑与外部 CLI agent。
3. 审查 UI、审计、冲突处理、恢复逻辑都可以统一。
4. 可扩展到后续云端 agent、后台任务和批量修复工作流。

缺点：

1. 需要新增隔离工作区层和提案持久化层。
2. 第一阶段实施成本高于简单 UI 修补。

结论：推荐采用。

## 6. 推荐总体方案

### 6.1 总体结论

推荐采用：

**统一 Change Review Pipeline + 双接入适配层 + 隔离工作区 / 提案缓冲层 + 统一 diff/revert/apply UI**。

总体结构如下：

```text
User Prompt
    │
    ▼
ConversationExecutionOrchestrator
    │
    ├── Built-in provider
    │      └── IntentCaptureAdapter
    │
    └── External ACP / CLI provider
           └── WorkspaceIsolationAdapter
                    │
                    ▼
             ChangeProposalStore
                    │
                    ├── Live Diff Projection
                    ├── Review UI Projection
                    ├── Audit Trail
                    └── ApplyEngine
                              │
                              ▼
                        Real Workspace
```

该方案有两个关键思想：

1. **改动先进入提案域，不直接进入真实工作区。**
2. **内建 provider 与外部 provider 只在“如何捕获改动”上不同，在“如何审查与 apply”上完全统一。**

### 6.2 两种捕获模式

#### A. `IntentCaptureAdapter`

适用于内建编辑工具，尤其是当前 text editor / patch tool 这类本就以 patch 或替换意图表达的路径。

特点：

1. 不必真的写磁盘。
2. 可直接从工具输入构造 patch。
3. 延迟到用户点击 `Apply` 时再真正写盘。

#### B. `WorkspaceIsolationAdapter`

适用于外部 ACP / CLI agent，这类 agent 可能会直接在工作目录执行多轮读写命令，不能假设它能在写盘前提供规范 patch。

特点：

1. provider 看到的是隔离工作区，而不是真实工作区。
2. agent 可以在隔离区内自由编辑、运行命令、生成中间文件。
3. App 持续对隔离区与真实工作区计算 diff，形成 live proposal。
4. 用户确认后，再由 `ApplyEngine` 将审核通过的改动落回真实工作区。

这是让外部 agent 支持“最终确认前可 revert”的唯一稳健路线。

## 7. 隔离工作区设计

### 7.1 为什么不能只用 Git worktree

裸 `git worktree` 方案有一个重要问题：

1. 如果用户当前工作区有未提交改动，新的 worktree 默认只基于某个 commit，无法天然继承当前脏工作区状态。

因此不能把“worktree”当成唯一隔离手段。

### 7.2 推荐的隔离后端抽象

建议引入协议：

```swift
protocol WorkspaceIsolationBackend {
    func prepare(sessionID: String, sourceRoot: URL) async throws -> IsolatedWorkspaceHandle
    func diff(handle: IsolatedWorkspaceHandle) async throws -> [ProposedFileChange]
    func discard(handle: IsolatedWorkspaceHandle) async throws
    func cleanup(handle: IsolatedWorkspaceHandle) async
}
```

并实现三种后端：

1. `APFSCloneBackend`
   - macOS 首选。
   - 通过 APFS clone / copy-on-write 快速复制当前工作区，保留用户未提交改动的真实起点。
2. `GitWorktreeBackend`
   - 适用于干净仓库或后台云端任务。
   - 对大仓库更节省初始时间，但不能覆盖所有本地脏工作区场景。
3. `DirectIntentBackend`
   - 给内建 patch 工具使用，不创建真正隔离目录，只维护提案缓冲层。

当前仓库是 macOS SwiftUI 应用，因此第一阶段推荐以 `APFSCloneBackend + DirectIntentBackend` 为主。

### 7.3 隔离工作区生命周期

`IsolatedWorkspaceHandle` 建议包含：

```swift
struct IsolatedWorkspaceHandle: Sendable {
    let id: UUID
    let sessionID: String
    let jobID: UUID?
    let sourceRoot: URL
    let isolatedRoot: URL
    let backendKind: IsolationBackendKind
    let createdAt: Date
}
```

生命周期：

1. execution job 启动时创建。
2. provider 在隔离区运行。
3. diff watcher 持续计算变更。
4. job 结束后提案进入待审查。
5. 用户 `Apply` 或 `Discard` 后清理隔离区。
6. 应用异常退出时，下次启动恢复待审查提案并尝试清理孤儿隔离区。

## 8. 核心领域模型

### 8.1 `ChangeProposal`

建议新增持久化聚合体：

```swift
enum ChangeProposalState: String, Codable, Sendable {
    case collecting
    case readyForReview
    case partiallyApproved
    case applying
    case applied
    case discarded
    case conflicted
    case failed
}
```

建议字段：

1. `id`
2. `sessionID`
3. `jobID`
4. `messageID`
5. `providerID`
6. `state`
7. `isolationHandleID`
8. `baseWorkspaceRoot`
9. `baseRevisionHint`，可选 commit hash / workspace fingerprint
10. `summary`
11. `riskLevel`
12. `createdAt`
13. `updatedAt`
14. `appliedAt`
15. `discardedAt`

### 8.2 `ProposedFileChange`

```swift
enum ProposedFileChangeState: String, Codable, Sendable {
    case proposed
    case accepted
    case rejected
    case revertedBeforeApply
    case applied
    case conflict
    case failed
}
```

建议字段：

1. `proposalID`
2. `relativePath`
3. `absolutePath`
4. `changeKind`，如 add / modify / delete / rename
5. `baseContentHash`
6. `isolatedContentHash`
7. `unifiedDiff`
8. `lineAdditions`
9. `lineDeletions`
10. `state`
11. `riskFlags`

### 8.3 `ChangeReviewDecision`

用于审计用户动作：

1. 决策人
2. 动作类型：apply all / apply selected / discard / revert file / reopen review
3. 时间戳
4. 目标文件集合
5. 备注或失败原因

### 8.4 为什么不直接把这些状态塞进 `ToolCall`

因为提案与工具调用不是 1:1：

1. 一个 agent 回合可能有多个 edit tool call，却对应一个用户想要整体审查的改动包。
2. 一个提案也可能聚合“编辑文件 + 运行格式化 + 更新测试”的最终工作区结果。
3. `ToolCall` 是动作记录，`ChangeProposal` 是工作区结果记录，职责不同。

推荐关系是：

1. `ToolCall` 只保留简要 diff 摘要与 `proposalID` 引用。
2. 真正的审查与 apply 逻辑统一挂在 `ChangeProposal` 聚合下。

## 9. 状态机设计

### 9.1 提案状态机

```text
collecting
   │
   ├── agent finished ─────────────► readyForReview
   ├── user stop + keep partial ───► readyForReview
   ├── user discard ───────────────► discarded
   └── capture failure ────────────► failed

readyForReview
   │
   ├── apply all/selected ─────────► applying
   ├── revert files in draft ──────► partiallyApproved / readyForReview
   ├── discard ────────────────────► discarded
   └── base changed ───────────────► conflicted

applying
   │
   ├── success ────────────────────► applied
   ├── partial conflict ───────────► conflicted
   └── apply failure ──────────────► failed
```

### 9.2 与 execution runtime 的关系

execution job 与 change proposal 应是两个并行维度：

1. `ExecutionJob` 表示“agent 是否还在工作”。
2. `ChangeProposal` 表示“工作区结果是否等待用户决定”。

因此：

1. job 完成后，proposal 仍可能处于 `readyForReview`。
2. session UI 需要同时展示：
   - 是否仍在运行
   - 是否有待审查变更

这避免把“执行结束但待审查”误判成“完全结束”。

## 10. 关键模块设计

### 10.1 `ChangeProposalStore`

职责：

1. 持久化提案与文件变更。
2. 提供按 `sessionID`、`jobID`、`state` 查询。
3. 恢复 app 重启后的待审查提案。

这层只负责 durable state，不负责 diff 计算或 UI。

### 10.2 `ChangeCaptureCoordinator`

职责：

1. 接收 built-in intent 或 isolated workspace watcher 的变更事件。
2. 归一为 `ProposedFileChange`。
3. 负责去重、合并与摘要更新。

关键原则：

1. 这层构造的是“最终工作区结果”，不是工具执行日志。
2. 即使一个文件被多次编辑，也应该归并成当前提案下该文件的最新版本 diff。

### 10.3 `LiveDiffService`

职责：

1. 对隔离工作区持续扫描。
2. 生成统一 diff 文本。
3. 输出给提案存储层与 UI 投影层。

建议：

1. 优先生成 unified diff，因为现有 `GitDiffView` 已可复用。
2. 对大文件和二进制文件提供降级摘要，而不是阻塞整个提案。

### 10.4 `ChangeReviewProjectionStore`

职责：

1. 给 SwiftUI 提供可观察快照。
2. 提供 session 级 badge，例如：
   - 待审查文件数
   - 高风险文件数
   - 当前选中文件
3. 驱动聊天区、工具泡泡、主编辑区 review 页面。

### 10.5 `ApplyEngine`

这是系统里唯一允许写真实工作区的模块。

职责：

1. 按用户批准的文件集合执行 apply。
2. 在 apply 前验证 base fingerprint 是否仍匹配。
3. 生成 apply 结果和失败报告。
4. 维护 post-apply rollback 所需的反向 patch 或备份。

原则：

1. **真实工作区写入只能从这里发生。**
2. built-in 工具和外部 provider 都不能绕过它直接成为最终写入源。

### 10.6 `DraftRevertService`

职责：

1. 在提案未 apply 前，对单文件或整批提案执行回退。
2. 对 `IntentCaptureAdapter`，回退等价于删除对应 patch 条目。
3. 对 `WorkspaceIsolationAdapter`，回退等价于把隔离区文件恢复为 base 版本。

这才是真正意义上的“apply 前 revert”。

### 10.7 `ConflictResolver`

当用户在 agent 运行后自己又修改了真实工作区，或者另一条流程改变了同一文件时，直接 apply 可能覆盖用户新改动。

因此必须在 apply 前检查：

1. file hash 是否仍与提案生成时一致。
2. 如果不一致，是否能自动三方合并。
3. 否则将提案标记为 `conflicted`，要求用户手动处理。

## 11. 核心交互流程

### 11.1 内建工具路径

```text
Agent requests edit
    ▼
IntentCaptureAdapter builds patch
    ▼
ChangeProposal enters collecting
    ▼
UI shows live diff / pending badge
    ▼
User clicks Apply / Discard / Revert File
    ▼
ApplyEngine writes selected changes to real workspace
```

关键点：

1. 不需要真实写盘就能得到 diff。
2. 回退只是删除提案内容，不存在真实文件恢复成本。

### 11.2 外部 ACP / CLI 路径

```text
Execution job starts
    ▼
WorkspaceIsolationAdapter prepares isolated workspace
    ▼
Provider runs against isolated root
    ▼
LiveDiffService watches isolated root and updates proposal
    ▼
User may Stop and inspect partial diff
    ▼
Job finishes -> proposal readyForReview
    ▼
User Apply / Apply Selected / Discard
    ▼
ApplyEngine merges approved changes into real workspace
```

关键点：

1. 支持 live diff。
2. 支持中途 `Stop` 后保留部分结果。
3. apply 前的 discard 是真正的零风险操作，因为真实工作区尚未被写入。

### 11.3 局部接受

第一阶段建议支持：

1. `Apply All`
2. `Apply Selected Files`
3. `Discard File`
4. `Discard Proposal`

不建议第一阶段直接做任意 hunk 级交互式编辑，原因：

1. 复杂度高。
2. 与冲突检测和回写一致性耦合较重。

但数据模型需要为第二阶段预留 `fileChunks` 或 `hunkDecisions` 扩展点。

## 12. UI 方案

### 12.1 聊天区最小可见反馈

在聊天区顶部或输入区附近新增 session 级 review badge：

1. `3 个文件待审查`
2. `1 个高风险改动`
3. `打开 Diff`

这对应论文中的：

1. efficient invocation
2. contextually relevant information
3. clear why the system did what it did

### 12.2 ToolCall 泡泡增强

`ToolCallBubbleView` 不需要承载完整审查器，但应展示：

1. 当前工具调用是否产生提案。
2. 提案中的文件数与摘要。
3. 跳转到 review 页面。

这样做可以保留工具调用可解释性，同时避免把复杂审查 UI 塞进泡泡细节区。

### 12.3 复用 `GitDiffView`

推荐直接复用现有 `GitDiffView` 的渲染能力：

1. `GitDiffView` 负责统一 diff 文本渲染。
2. 新增 `ChangeProposalReviewView` 作为容器。
3. 左侧显示文件列表与风险标签。
4. 中央 diff 仍使用现有统一 diff 解析逻辑。
5. 底部显示 `Apply`、`Apply Selected`、`Discard`、`Revert File`。

这样可以减少 UI 重复开发，并让“git diff”和“agent proposal diff”拥有一致的阅读体验。

### 12.4 高风险提示

对以下路径默认打高风险标签：

1. 配置与密钥文件
2. CI / scripts
3. 构建配置
4. 权限与网络相关代码
5. 删除操作

高风险文件默认需要更显眼的确认提示，但不应新增阻塞式二次弹窗泛滥，以免形成 prompt fatigue。

## 13. 策略与权限设计

### 13.1 审查模式

建议定义三档策略：

1. `manualReview`
   - 所有文件改动必须进入 review。
2. `acceptEditsBatch`
   - 允许低风险连续改动归并为一批，但仍需最终 apply。
3. `trustedAutoApply`
   - 仅保留为未来扩展，不建议当前仓库默认启用。

当前项目建议默认：`manualReview`。

### 13.2 组织与项目级规则

借鉴 Claude Code 的设置体系，本项目建议把以下规则做成项目 / 用户 / 组织三级配置：

1. 哪些路径永远需要人工确认。
2. 哪些 provider 只能在隔离工作区运行。
3. 允许自动 apply 的最大文件数 / 最大改动行数。
4. 对删除文件、重命名文件是否强制单独确认。

## 14. 与现有架构的集成建议

### 14.1 与 execution runtime 集成

推荐接入点：

1. `ConversationExecutionOrchestrator` 在 job 启动时为外部 provider 分配 isolation handle。
2. driver 在执行上下文中拿到 `effectiveWorkingDirectory`，优先指向 isolation root。
3. job 完成时，orchestrator 不直接宣告“全部结束”，而是同时查询是否生成了待审查 proposal。

### 14.2 与 provider 集成

对 `GitHubCopilotCLIExecutionProvider` 和 `OpenCodeCLIExecutionProvider`：

1. 不要求 provider 自己实现审查逻辑。
2. provider 只负责在隔离工作区中执行。
3. provider 可继续写 `ToolCall`、权限请求和运行日志。
4. proposal 由独立的 capture / diff 组件生成。

这能避免 provider 再次膨胀成“运行时 + 审查器 + 工作区写入器”的巨型对象。

### 14.3 与 built-in text editor 集成

当前 `ClaudeService+TextEditorTool` 中的直接文件写操作，需要改造成：

1. `view/read/open` 仍可直接读。
2. `str_replace/create/write/insert` 默认不再直接写真实文件。
3. 它们改为生成 `ChangeProposal` 条目。
4. 用户确认后再由 `ApplyEngine` 写真实文件。

这一步是整个方案真正闭环的关键。

## 15. 验证与测试策略

### 15.1 单元测试

需要覆盖：

1. `ChangeProposal` 状态机。
2. `LiveDiffService` 对新增 / 修改 / 删除 / rename 的 diff 生成。
3. `DraftRevertService` 的单文件和整批回退。
4. `ApplyEngine` 的部分应用、失败回滚和冲突检测。
5. app 重启后的 proposal 恢复和孤儿隔离区清理。

### 15.2 集成测试

需要覆盖：

1. built-in tool 生成待审查变更但不立即写盘。
2. Copilot / OpenCode 在隔离工作区内运行并产出 live diff。
3. 用户 `Stop` 后保留部分改动并进行 apply。
4. apply 前真实工作区被修改时，系统进入 `conflicted`。

### 15.3 UI 测试

需要覆盖：

1. 聊天区待审查 badge。
2. review 页面文件列表切换。
3. `Apply All`、`Apply Selected`、`Discard`、`Revert File`。
4. 高风险标签与冲突提示。

## 16. 分阶段落地建议

### Phase 1：统一领域模型与 review UI

1. 新增 `ChangeProposal`、`ProposedFileChange`、`ChangeReviewDecision`。
2. 新增 `ChangeProposalStore` 与 `ChangeReviewProjectionStore`。
3. 复用 `GitDiffView` 搭建 review 页面。
4. 先接入 built-in text editor 路径。

### Phase 2：外部 provider 隔离工作区

1. 为 Copilot / OpenCode 执行上下文增加 isolation backend。
2. 先实现 `APFSCloneBackend`。
3. 增加 live diff watcher。

### Phase 3：安全 apply 与冲突处理

1. 上线 `ApplyEngine`。
2. 引入 base fingerprint 与 conflict resolver。
3. 支持 `Apply Selected Files`。

### Phase 4：增强能力

1. hunk 级接受 / 拒绝。
2. post-apply 一键撤销。
3. 审查模式与组织级策略界面。
4. 风险评分与验证证据聚合展示。

## 17. 最终建议

本项目最合适的技术路线不是“给现有 diff 字段补一个 apply 按钮”，而是：

1. 将 agent 文件改动提升为独立领域对象 `ChangeProposal`。
2. 将真实工作区写入集中到唯一的 `ApplyEngine`。
3. 将外部 agent 迁移到隔离工作区执行。
4. 将内建编辑工具迁移到 intent-based staging。
5. 将现有 `GitDiffView` 和 tool UI 复用为统一的审查入口。

这样设计的收益是明确的：

1. 对用户，获得和主流 agent 一致的最终确认、live diff、可回退体验。
2. 对架构，避免把审查逻辑散落在各 provider 和 `ClaudeService` 中。
3. 对安全与质量，显著降低 agent 误改真实工作区、误覆盖用户修改和引入高风险变更的概率。
4. 对未来扩展，后续无论接新 provider、做后台 agent、做云端执行，都会自然复用同一条提交流程。

结论上，推荐以 **Change Review Pipeline** 作为本项目 agent 文件操作体验优化的核心方案，并以 **APFS 隔离工作区 + 统一提案模型 + 现有 Diff UI 复用** 作为第一阶段实现主线。

## 18. 参考资料

### 官方文档与产品资料

1. Cursor Learn: Reviewing and Testing
   - https://cursor.com/learn/reviewing-testing
2. Cursor Learn: Creating Features
   - https://cursor.com/learn/creating-features
3. GitHub Docs: About agent management
   - https://docs.github.com/en/copilot/concepts/agents/coding-agent/agent-management
4. Claude Code docs: Settings
   - https://code.claude.com/docs/en/settings
5. Claude Code docs: Security
   - https://code.claude.com/docs/en/security
6. OpenAI: Introducing Codex
   - https://openai.com/index/introducing-codex/
7. OpenAI: Introducing GPT-5.3-Codex
   - https://openai.com/zh-Hans-CN/index/introducing-gpt-5-3-codex/

### 论文与研究

1. Amershi et al., Guidelines for Human-AI Interaction, CHI 2019
   - https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/
2. Barke et al., Grounded Copilot: How Programmers Interact with Code-Generating Models
   - https://arxiv.org/abs/2206.15000
3. Perry et al., Do Users Write More Insecure Code with AI Assistants?
   - https://arxiv.org/abs/2211.03622
4. Liu et al., Is Your Code Generated by ChatGPT Really Correct? Rigorous Evaluation of Large Language Models for Code Generation
   - https://arxiv.org/abs/2305.01210