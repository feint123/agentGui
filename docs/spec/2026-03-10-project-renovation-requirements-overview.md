# agentGui 项目改造需求总览

日期：2026-03-10

目的：对当前 agentGui 项目做一轮按功能域拆分的改造盘点，明确哪些主题已经有完整需求文档，哪些主题仍需补齐，并为后续排期提供统一入口。

## 1. 总体判断

当前项目已经具备以下可用基础：

- Claude 对话、流式渲染、Agentic Loop、多轮工具调用
- Bash 工具、文件编辑工具、Web 工具、技能系统
- 子代理与工作流运行时
- 创作记忆、Markdown 消息渲染、块编辑器

但从“功能完整度”和“可长期演进”角度看，项目仍有七类高优先级改造空白：

1. 数据可靠性与故障恢复
2. 会话生命周期与发现能力
3. 安全、密钥与权限中心
4. 工作区上下文与项目边界
5. 工具扩展框架与生态接入
6. 测试体系与发布质量
7. 能力发现、引导与内建帮助

## 2. 本轮新增需求文档

本轮新增以下独立需求文档：

- `docs/spec/2026-03-10-data-reliability-and-recovery-requirements.md`
- `docs/spec/2026-03-10-session-lifecycle-and-discovery-requirements.md`
- `docs/spec/2026-03-10-security-and-permission-center-requirements.md`
- `docs/spec/2026-03-10-workspace-context-and-project-boundary-requirements.md`
- `docs/spec/2026-03-10-tool-extension-framework-requirements.md`
- `docs/spec/2026-03-10-testing-and-release-quality-requirements.md`
- `docs/spec/2026-03-10-capability-discovery-and-onboarding-requirements.md`

## 3. 已有文档，原则上不重复造轮子

以下主题已有较完整的评审或需求说明，本轮不再重复写同类文档：

- Bash 工具运行时：`docs/spec/2026-03-10-bash-tool-redesign-requirements.md`
- Agent 消息区 UI：`docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md`
- Markdown 渲染：`docs/spec/2026-03-10-markdown-message-view-requirements.md`
- Story Memory 创作记忆：`docs/spec/2026-03-09-story-memory-authoring-tools-requirements.md` 等
- Story Project Inspector：`docs/spec/2026-03-10-story-project-inspector-tabbed-requirements.md` 等
- 工作流编排主设计：`docs/workflow-orchestration-design-2026-03-08.md`

## 4. 推荐排期顺序

### P0：先补底层安全与稳定性

1. 数据可靠性与恢复
2. 安全、密钥与权限中心
3. 工作区上下文与项目边界

### P1：再补日常使用体验闭环

1. 会话生命周期与发现能力
2. 能力发现、引导与内建帮助

### P2：为规模化演进补基础设施

1. 工具扩展框架与生态接入
2. 测试体系与发布质量

## 5. 代码现状与本轮文档的对应关系

### 5.1 数据可靠性

当前 `AppSettings.getOrCreate(...)`、`persistPlan(...)`、`WorkflowRuntime.startWorkflow(...)` 等路径里仍存在 `try? modelContext.save()` 的静默失败；`sessionTodoLists`、`sessionVerifications` 仍驻留在内存，不具备恢复能力。

### 5.2 会话与发现能力

`SessionListView` 当前仍是基础列表，仅支持创建、删除与点击进入；缺少搜索、过滤、分组、标签、置顶、导出、归档与分支。

### 5.3 安全与权限

`AppSettings` 仍直接保存 `apiKey`；工具权限主要是全局开关，缺少按工具类别、目录边界、风险等级和运行模式进行治理。

### 5.4 工作区边界

`Session` 已有 `workingDirectory` 字段，但 `WorkspacePanelView` 仍主要基于全局 `AppSettings.workingDirectory`；会话、工作区、当前文件、选区三者之间的绑定关系还不完整。

### 5.5 扩展框架

`ClaudeService+ToolBuilder` 里仍以硬编码方式构建工具；`SkillService` 解决的是技能加载，不是工具注册、版本协商或第三方扩展。

### 5.6 质量保障

当前单元测试覆盖不错，但 UI Tests 仍基本是 Xcode 默认模板，缺少端到端工作流、回归基线和发布前校验矩阵。

### 5.7 用户引导

README 和 docs 主要服务开发者；应用内缺少帮助中心、能力浏览器、失败诊断入口与首次使用引导。

## 6. 预期输出

本轮文档的目的不是直接安排实现细节，而是建立下一阶段的“功能改造菜单”。后续可以按文档逐项转为实现计划与测试计划。