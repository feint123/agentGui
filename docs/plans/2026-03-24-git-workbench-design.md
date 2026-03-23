# Workbench Git 模块设计

日期：2026-03-24

## 目标

为 agentGui 的 Workbench 侧边栏设计一套优秀、模块化、可扩展的 Git 体验。短期目标不是做一个全量 Git 客户端，而是在现有工作台上下文中，把最常用、最有价值、最不容易出错的 Git 能力做成稳定底座，并为后续历史图、冲突解决、远端协作和 AI 辅助预留清晰扩展点。

## 当前现状

当前实现已经有一个很薄的 Git 面板壳层和一个可复用的 GitPanelView：

- 状态读取：可以刷新仓库快照。
- 仓库摘要：显示仓库名、当前分支、ahead/behind、staged/modified/untracked 数量。
- 分支切换：可以读取分支列表并切换分支。
- Diff 打开：可针对文件变化拉取 diff，并投影到 Workbench context window。

现有数据模型也比较克制：

- GitRepositorySnapshot 只表达工作区快照。
- GitFileChange 只表达文件级变化。
- GitPanelViewModel 负责 refresh、switchBranch、selectDiff。

这说明当前结构适合作为“Git 状态面板”的最小基础，但还没有形成完整的 Source Control 工作流。缺口主要在三个方向：

1. 缺少提交工作流，无法完成 stage、unstage、discard、commit 的闭环。
2. 缺少历史与图谱，无法支撑 branch graph、commit review、revert/cherry-pick/squash 这类高价值操作。
3. 缺少操作分层，当前 ViewModel 已经承担读取和交互投影，继续堆功能会很快失控。

## 热门产品调研结论

本次参考了几类广泛使用的产品与文档：VS Code Source Control、GitHub Desktop、GitKraken、Sublime Merge。

### 共同的基础能力

这些产品虽然定位不同，但基础盘几乎一致：

- 工作区状态总览：仓库、分支、ahead/behind、变更计数。
- 变更审查：文件 diff、统一/分栏视图、隐藏空白差异、展开上下文。
- 精细暂存：文件级、hunk 级，成熟产品通常还支持行级暂存。
- 提交闭环：commit message、amend、hook/ruleset 提示、push/pull/fetch。
- 分支操作：切换、创建、删除、检出远端分支。
- 历史操作：revert、cherry-pick、reset、squash、reorder。
- 上下文恢复：stash 是高频基础能力，不是高级能力。
- 冲突处理：至少要明确冲突文件列表、状态、进入解决入口。
- 搜索/过滤：在变更列表和提交历史里快速定位目标。

### 各产品值得借鉴的点

VS Code 的优势在于“编辑器内工作流闭环”：Source Control 视图、Graph、Timeline、gutter/blame、冲突编辑器互相联动。它的启示是，Git 不应该只是一个独立面板，而应当成为工作台上下文的一部分。

GitHub Desktop 的优势是 80/20 取舍非常清晰：用最少的认知负担覆盖 review、partial commit、discard、amend、reorder、squash、cherry-pick、revert。它的启示是，基础能力优先级应围绕“日常提交质量”展开，而不是先堆高级图形化功能。

GitKraken 的优势是把历史图、分支关系、协作状态和高级操作做成中心视图。它的启示是，历史图谱应作为独立模块，不要耦合在状态面板里。

Sublime Merge 的优势是快、准、搜索强，以及对真实 Git 命令的透明度高。它的启示是，agentGui 需要保留“看得见底层命令与失败原因”的调试通路，否则高级操作会难以维护。

## 设计原则

### 1. 以工作台为中心，而不是以 Git 客户端为中心

用户在 agentGui 中的主任务不是管理仓库，而是围绕当前会话、当前文件、当前 diff 做判断与行动。因此 Git 模块应优先强化与当前文件、文件树、diff 预览、会话上下文的联动。

### 2. 状态读取与写操作严格分层

读取类能力和写操作类能力必须拆开。读取可高频刷新、可缓存、可容错；写操作需要串行、可回滚、可审计、可恢复提示。否则 UI 很容易因为异步状态竞争而出现错误投影。

### 3. 面板分区固定，能力逐步扩张

Git 面板不应随功能增长而变成一个无限滚动的大杂烩。推荐固定为几个稳定分区：概览、变更、提交、分支与同步、历史入口、更多操作。后续新增能力只挂到既有分区中。

### 4. 高级操作延后，但架构今天就要预留

cherry-pick、rebase、squash、reset、stash pop 这类操作短期可不全部交付，但数据模型、命令层和错误模型要从第一天就支持扩展。

## 建议补齐的基础能力

### P0：必须补齐

这些能力缺一项，Git 面板都很难形成真正可用的日常工作流：

- 文件级 stage / unstage。
- discard changes，至少支持文件级。
- commit 输入区，包含 summary、description、提交按钮、提交前校验。
- fetch / pull / push / sync 基础远端操作。
- 创建分支与检出分支，而不只是切换已有分支。
- stash save / stash apply / stash pop 的最小入口。
- 变更列表过滤，至少支持按文件名搜索与 section 过滤。
- 操作中的错误反馈与命令透明度，明确告诉用户失败在哪条 Git 命令。

### P1：强烈建议尽快补齐

- hunk 级 diff 与 hunk 级 stage / unstage。
- amend last commit。
- 提交历史列表。
- 从历史执行 revert / cherry-pick。
- 冲突文件分组与“打开冲突解决视图”入口。
- 当前文件历史和 blame 入口，与编辑区联动。

### P2：体验拔高项

- branch graph 视图。
- split/unified diff 切换、隐藏空白差异、扩展上下文。
- AI 生成 commit message。
- 受保护分支提示、hooks/rulesets 提示。
- 多仓库 / nested repo 感知。
- worktree 入口。

## 信息架构

建议将侧边栏 Git 面板分成 6 个稳定模块。

### 1. Repository Overview

显示仓库名、当前分支、remote tracking、ahead/behind、最近刷新时间、仓库健康状态。

作用：给用户一个极低成本的“我现在在哪、仓库是不是正常”的判断点。

### 2. Changes

显示 staged、modified、untracked 三个 section，并支持：

- section 折叠
- 文件搜索
- 文件级 stage / unstage / discard
- 选中后在 context window 或主区域预览 diff

这一块应成为 Git 面板的中心，而不是摘要卡片。

### 3. Commit Composer

显示 summary、description、co-author 预留位、amend 开关、commit 按钮。

提交按钮状态需要可解释：

- 无 staged 内容时为什么不能提交
- hooks 或 rules 校验失败时怎么处理
- 是否允许 commit all

### 4. Branch & Sync

显示当前分支、最近分支、创建分支、切换分支、fetch/pull/push/sync。

这里不展示完整图谱，只做日常分支与同步控制。

### 5. History

最初版本可只提供“最近提交列表 + 更多历史”。后续可升级为 graph。

列表项需要支持：

- 查看提交 diff
- revert
- cherry-pick
- copy SHA

### 6. Utilities

收纳低频但必要的动作：stash、open in terminal、open repo root、copy branch name、diagnostics/logs。

## 推荐模块划分

为避免 GitPanelViewModel 继续膨胀，建议拆成以下层次。

### 视图层

- WorkbenchGitPanelView：Workbench 容器和刷新边界。
- GitSidebarOverviewSection
- GitSidebarChangesSection
- GitSidebarCommitSection
- GitSidebarBranchSection
- GitSidebarHistorySection
- GitSidebarUtilitiesSection

### 展示状态层

- GitSidebarViewModel：只负责组合展示数据与派发用户意图。
- GitOperationState：统一表达 loading、success、failure、disabledReason。
- GitSelectionState：当前选中 change、commit、branch、stash。

### 领域服务层

- GitStatusService：读取 snapshot、branches、history、stash、remotes。
- GitMutationService：stage、unstage、discard、commit、switch、createBranch、sync、stash。
- GitHistoryService：commit list、commit detail、revert、cherry-pick。
- GitConflictService：冲突检测、冲突文件摘要、入口投影。

### 命令执行层

- GitCommandRunner：统一执行 git 命令。
- GitCommandResult：stdout、stderr、exitCode、duration、displayCommand。
- GitCommandError：标准化失败模型，支持用户可读消息和调试详情。

### 缓存与刷新层

- GitSnapshotStore：当前仓库快照缓存。
- GitRefreshCoordinator：负责去重刷新、节流、写操作后的失效更新。

## 关键数据模型建议

在现有 GitRepositorySnapshot 之外，建议逐步新增：

- GitRemoteStatus：remote name、tracking branch、ahead、behind、lastFetchAt。
- GitCommitSummary：sha、author、date、subject、isHead、refs。
- GitCommitDetail：summary + changedFiles + diff stats。
- GitStashEntry：id、title、createdAt、branchContext。
- GitConflictItem：path、conflictType、isBinary、hasMergeMarkers。
- GitCapabilitySet：当前仓库和当前 provider 支持哪些能力。

GitCapabilitySet 很关键。它允许未来根据环境动态降级，例如：

- 没有远端时隐藏 sync 动作。
- 仓库处于 merge/rebase 中时禁用部分危险操作。
- 某些 provider 或受限环境只开放只读能力。

## 交互设计要点

### 1. 一眼能看懂当前仓库状态

顶部不是大卡片堆叠，而是紧凑、强信息密度的概览行：

- 仓库名
- 当前分支
- ahead/behind
- working tree 状态 badge
- refresh

### 2. Changes 要把“行动”放在第一位

每个文件项至少提供：

- 点击预览 diff
- stage/unstage
- 更多菜单：discard、reveal in finder、copy path

如果后续支持 hunk 级 staging，不应直接塞进文件列表，而应在 diff 预览区完成。

### 3. 提交区固定在面板下半部分

原因很简单：用户在查看变更之后，视线自然会落到提交区。把 commit input 做成稳定位置，比把它藏在菜单里更符合日常工作流。

### 4. 高风险动作必须带语义确认

discard、reset、force push、drop stash、hard reset 这类动作要统一走风险确认模型，而不是每个按钮各写一套 alert。

## 与当前 Workbench 的联动建议

- Workspace 文件树继续显示 Git 变化标记，但 Git 面板负责执行操作。
- 点击 Git change 时继续复用现有 context window diff 能力。
- 当前选中文件若存在历史，可在 Git 面板或上下文菜单中提供 file history 入口。
- 后续若加入 blame，应作为编辑器附加信息，而不是塞进侧边栏。

## 技术演进顺序

### 第一阶段：完成日常闭环

- 把现有 Git 面板拆成独立 section 视图。
- 新增 GitMutationService。
- 加入 stage / unstage / discard / commit / push / pull / fetch。
- 完成操作错误模型和统一 toast/alert。

交付标准：用户可以在不离开 agentGui 的情况下完成一次标准提交与同步。

### 第二阶段：补齐历史与 stash

- 加入 commit history list。
- 加入 stash list。
- 支持 amend、revert、cherry-pick。

交付标准：用户可以完成常见修正与上下文切换，不依赖终端。

### 第三阶段：图谱与冲突

- branch graph。
- merge/rebase 过程状态展示。
- 冲突文件列表与解决入口。

交付标准：复杂分支场景不再需要立即切回外部 Git 客户端。

## 非目标

以下内容当前不建议作为第一轮目标：

- 完整替代 Tower / GitKraken 的所有高级历史编辑能力。
- 一开始就做多仓库聚合图谱。
- 在侧边栏内实现完整三方合并编辑器。
- 先做 AI 生成 commit message，再补基础 stage/commit 闭环。

## 推荐结论

如果只选最值得立刻做的一批基础能力，我建议是：

1. stage / unstage / discard
2. commit composer
3. fetch / pull / push / sync
4. create branch / checkout branch
5. stash
6. history list + revert / cherry-pick 入口

这组能力最符合 VS Code 与 GitHub Desktop 的高频主路径，也最适合当前 agentGui 已有的数据与 UI 结构。它们能把 Git 面板从“状态展示”升级为“可完成日常 Git 工作”的工作区模块，同时仍保持实现边界清晰，便于未来往 graph、conflict、AI 辅助方向继续演进。