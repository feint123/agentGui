# 基础 Git UI 交互需求说明

日期：2026-03-11

关联对象：`WorkspacePanelView`、`FileEditorView`、`MainSplitView`、`AppSettings.workingDirectory`、`BashSession`、`ClaudeService+BashTool`

## 1. 背景

当前项目已经具备以下基础能力：

- 基于工作目录的文件树浏览与文件编辑
- 基于 `BashSession` 的受管 shell 命令执行
- 会话级聊天与工具时间线展示

但对于本地 Git 仓库，当前应用仍停留在“用户自己在终端执行 Git 命令”的阶段，缺少最基本的可视化状态查看和常用操作入口。这会带来三个直接问题：

- 用户无法在应用内快速判断当前工作区是否干净、当前分支是什么、有哪些文件被修改
- 用户在查看文件时，无法直接从 UI 触发暂存、取消暂存、查看 diff、提交等基础操作
- agent 侧虽然可以调用 Bash，但普通用户侧缺少一层稳定、低风险、低认知负担的 Git 交互界面

本需求说明的目标，不是把 agentGui 做成完整 Git 客户端，而是在现有工作区 UI 基础上补齐“最基本、最常用、最安全”的 Git 图形交互闭环。

## 2. 目标

为当前应用增加一个可在工作区内直接使用的基础 Git UI，使用户能够完成以下最小闭环：

- 识别当前工作目录是否位于 Git 仓库中
- 查看当前分支与工作区变更摘要
- 查看文件级变更列表与 diff
- 对文件执行暂存、取消暂存、丢弃改动等基础操作
- 输入提交信息并完成一次非交互式 commit

## 3. 不在本次范围

- 不实现完整 Source Control 客户端
- 不做分支创建、切换、删除、合并、变基、cherry-pick
- 不做 `git add -p`、交互式 rebase、无消息 commit 等交互式 Git 流程
- 不做冲突解决器、三方 diff、hunk 级操作
- 不做历史提交浏览、blame、tag、stash 管理
- 不把 Git 状态持久化为长期业务数据；V1 以运行时查询为主

## 4. 现状约束

当前 Bash 运行时已经将以下 Git 命令视为高风险或交互式命令：

- `git add -p`
- `git rebase -i`
- 不带 `-m` 的 `git commit`

这意味着 Git UI 首版必须坚持两个边界：

- 所有 Git 操作都应尽量映射到非交互式命令
- 一旦涉及鉴权、冲突、编辑器接管或用户自由输入回填终端，必须在 UI 层阻断或降级，而不是硬做自动处理

## 5. 方案对比

### 方案 A：仅增加 Git 菜单命令

做法：在工具栏或右键菜单里直接挂若干 Git 操作按钮，执行后只用 toast 或日志反馈结果。

优点：

- 实现最轻
- 对现有 UI 改动最少

缺点：

- 用户看不到整体仓库状态
- 操作是“盲执行”，可理解性弱
- 不形成完整 UI 闭环

### 方案 B：工作区内嵌基础 Git 面板

做法：在现有工作区侧栏内增加 Git 状态区，展示分支、变更列表和提交入口；文件编辑区补一个 diff 预览；高频操作在文件列表和详情内直接触发。

优点：

- 与当前三栏布局贴合，学习成本低
- 只覆盖最基础路径，复杂度可控
- 能充分复用现有工作目录、文件树和 Bash 执行能力

缺点：

- 仍需设计一套轻量状态模型和刷新机制
- 首版 diff 能力需要克制，不能一步做到 IDE 级体验

### 方案 C：独立 Source Control 标签页

做法：仿照 IDE 的 Source Control 模式，增加独立一级导航和完整 Git 工作流。

优点：

- 可扩展性强
- 后续容纳更完整 Git 能力更自然

缺点：

- 对当前产品信息架构改动过大
- 超出“最基本 Git UI”范围
- 首版投入与收益不匹配

结论：V1 采用方案 B。

## 6. 功能范围

### 功能点 1：仓库识别与状态摘要

需求：

- 当当前工作目录处于 Git 仓库内时，UI 应能识别仓库根目录
- 在侧栏顶部展示当前仓库名、当前分支名、是否存在未提交改动
- 当目录不是 Git 仓库时，Git 区域显示空态，而不是报错
- 当工作目录是仓库子目录时，仍应以仓库根目录为 Git 作用边界

建议展示信息：

- 仓库名
- 当前分支
- `ahead/behind` 简要状态；若首版实现成本偏高，可降级为仅显示分支
- 变更统计：已暂存、未暂存、未跟踪文件数量

### 功能点 2：变更列表

需求：

- 在侧栏中展示变更文件列表，至少区分以下分组：`Staged`、`Modified`、`Untracked`
- 每个文件项展示相对路径、文件状态标记和基础操作入口
- 点击文件项后，用户可以查看该文件当前变更的 diff
- 文件树中已变更文件应有轻量状态标识，避免用户只能进入 Git 面板才能发现变更

首版建议的文件状态映射：

- `A`：新增
- `M`：修改
- `D`：删除
- `R`：重命名
- `?`：未跟踪

### 功能点 3：Diff 预览

需求：

- 用户点击某个变更文件后，应能查看该文件的 Git diff
- 对已暂存文件与未暂存文件，应能区分查看对应 diff
- 首版允许使用“补丁文本视图”而非富文本逐行对比视图
- 当文件为二进制、体积过大或 diff 不可显示时，应给出明确提示

交互要求：

- 默认在中间编辑区域切换到 diff 预览，或以 sheet / inspector 形式展示
- 用户仍可从同一入口回到普通文件内容查看

### 功能点 4：基础 Git 操作

需求：

- 支持对单个文件执行 `暂存`
- 支持对单个文件执行 `取消暂存`
- 支持对单个未暂存文件执行 `丢弃改动`
- 支持对单个未跟踪文件执行 `删除并移除未跟踪状态`
- 支持 `全部暂存`
- 每次操作完成后自动刷新仓库状态

安全边界：

- `丢弃改动` 与删除未跟踪文件必须二次确认
- 不支持 hunk 级暂存
- 不支持批量危险操作的无确认执行

### 功能点 5：Commit 提交流程

需求：

- Git 面板中提供提交信息输入区
- 仅当存在已暂存改动且提交信息非空时，提交按钮可用
- 提交应使用非交互式方式完成，不允许拉起终端编辑器
- 提交成功后清空输入框并刷新仓库状态
- 提交失败时，展示结构化错误信息

提交边界：

- V1 只支持普通本地提交
- 不支持 amend、签名提交、co-author、模板消息等高级选项

### 功能点 6：刷新与错误反馈

需求：

- 提供手动刷新入口
- 在工作目录切换、应用回前台、Git 操作完成后自动刷新状态
- Git 命令失败时，UI 需要区分以下错误类型：
  - 当前目录不是 Git 仓库
  - 仓库状态读取失败
  - 文件状态已变化，当前操作失效
  - commit 失败
  - pull/push 等未纳入首版范围的操作不可用

### 功能点 7：最小远端同步状态提示

需求：

- V1 不要求实现完整 pull/push UI
- 但允许在仓库摘要中显示“是否存在远端跟踪分支”与基础 ahead/behind 信息
- 若后续要扩展 `Push` / `Pull`，必须先补齐鉴权失败、冲突、网络异常的结构化处理

## 7. UI 设计要求

### 7.1 入口位置

推荐采用以下挂载方式：

- 在 `WorkspacePanelView` 顶部目录栏下方增加 Git 摘要区
- 在文件树前或文件树内部增加“变更文件”分组入口
- 在文件行右键菜单或悬浮操作中增加 Git 动作
- 在中间编辑区提供 diff 预览模式

### 7.2 空态

非 Git 目录时，Git 区域显示：

- 当前目录不是 Git 仓库
- 可提示用户在终端初始化仓库，但首版不在 UI 中直接提供 `git init`

无变更时，Git 区域显示：

- 当前分支
- 工作区干净
- commit 输入区默认折叠或弱化展示

### 7.3 操作反馈

- 成功操作使用轻量 toast / banner 反馈
- 危险操作使用确认对话框
- Git 正在刷新时显示明确 loading 状态，避免重复点击

## 8. 数据与技术要求

### 8.1 状态模型

V1 建议采用运行时 ViewModel，而不是 SwiftData 持久化模型。

建议最小状态结构：

```swift
struct GitRepositorySnapshot {
    var repositoryRoot: URL
    var repositoryName: String
    var branchName: String
    var hasRemoteTrackingBranch: Bool
    var aheadCount: Int
    var behindCount: Int
    var stagedChanges: [GitFileChange]
    var unstagedChanges: [GitFileChange]
    var untrackedChanges: [GitFileChange]
}

struct GitFileChange: Identifiable, Equatable {
    var id: String { relativePath + ":" + status.rawValue + ":" + section.rawValue }
    var relativePath: String
    var absoluteURL: URL
    var status: GitChangeStatus
    var section: GitChangeSection
}
```

### 8.2 命令边界

首版建议仅通过非交互式 Git 命令实现：

- `git rev-parse --show-toplevel`
- `git status --porcelain=v1 --branch`
- `git diff -- <path>`
- `git diff --cached -- <path>`
- `git add -- <path>`
- `git add --all`
- `git restore --staged -- <path>`
- `git restore -- <path>`
- `git clean -f -- <path>`
- `git commit -m <message>`

禁止纳入首版 UI 的命令：

- `git add -p`
- `git rebase -i`
- 无 `-m` 的 `git commit`
- 任何依赖编辑器接管或密码交互的命令流程

### 8.3 与现有架构的关系

- Git UI 不应直接复用 Agent 工具调用时间线作为主用户交互界面
- Git 命令执行可复用底层 Bash 执行能力，但上层需要单独的 GitService / GitViewModel 进行封装
- Git UI 的失败信息应面向普通用户，而不是直接暴露原始命令行术语

## 9. 验收标准

- 用户在一个 Git 工作目录中打开应用后，能稳定看到当前分支和文件变更摘要
- 对一个已修改文件，用户能从 UI 查看 diff，并完成暂存
- 对一个已暂存文件，用户能从 UI 取消暂存
- 对一个未暂存文件，用户在确认后能从 UI 丢弃改动
- 对一组已暂存改动，用户输入提交信息后能成功完成本地 commit
- 非 Git 目录、空仓库、二进制文件 diff、命令失败等场景下，UI 表现明确且不崩溃

## 10. 优先级

- P0：仓库识别、状态摘要、变更列表、diff 预览、暂存/取消暂存、commit
- P1：文件树状态装饰、全部暂存、ahead/behind 展示、应用生命周期自动刷新
- P2：远端同步入口、批量操作、更多 diff 展示优化

## 11. 后续扩展方向

在 V1 稳定后，可按以下顺序扩展：

1. `Push` / `Pull` 按钮与远端同步错误处理
2. 提交历史列表与单提交详情
3. 分支切换与创建
4. 冲突检测与冲突解决引导
5. hunk 级暂存与更高保真 diff 视图
