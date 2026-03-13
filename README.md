# agentGui

一个现代化的 macOS 原生 AI Agent 客户端，基于 Anthropic Claude API 构建。

## 特性

- **原生 macOS 体验** - 使用 SwiftUI 构建，完美适配 macOS 设计语言
- **Claude API 集成** - 支持所有 Claude 模型（Opus 4.6、Sonnet 4.6、Haiku 4.5 等）
- **多会话管理** - 创建和管理多个对话会话，历史记录本地持久化
- **Agentic Loop** - 完整的多轮工具调用循环，支持复杂任务分解与执行
- **子代理协作** - 内置 8 种专业子代理，支持任务委派和协作
- **工具生态** - 文件编辑、受管 Bash 终端、Web 搜索、图片分析、PDF 读取等
- **技能系统** - 扩展 AI 能力的自定义技能，兼容 Claude Code 技能格式
- **长期记忆** - 在项目记忆目录中持久化跨会话的知识
- **创作记忆** - 面向小说写作的项目级结构化记忆，维护角色、世界规则、时间线和连续性
- **统一记忆运行时** - 任务记忆与创作记忆统一落到 MemoryRecord / unified store，按任务类型选择不同 Profile 和记忆层
- **Extended Thinking** - 支持 Claude 3.7+ 的深度推理模式
- **流式响应** - 实时显示 AI 回复，支持 Markdown 渲染
- **Timeline 视图** - 可视化展示 Agent 执行过程和工具调用链
- **块编辑器** - 类似 Notion 的文档编辑器，支持 16+ 种块类型、斜杠命令、行内样式工具栏

## 系统要求

- macOS 15.0+
- Xcode 16.3+
- Swift 6.0+

## 构建

```bash
# 克隆仓库
git clone https://github.com/feint/agentGui.git
cd agentGui

# 在 Xcode 中打开
open agentGui.xcodeproj

# 或使用命令行构建
xcodebuild -project agentGui.xcodeproj -scheme agentGui build
```

## 质量基线

当前推荐至少跑两组 focused gates：

```bash
# 场景级单元 / 集成验证
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
    -only-testing:agentGuiTests/QualityFixtureBuilderTests \
    -only-testing:agentGuiTests/ReleaseScenarioTests

# UI 冒烟回归
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
    -only-testing:agentGuiUITests/SessionManagementUITests \
    -only-testing:agentGuiUITests/SettingsUITests \
    -only-testing:agentGuiUITests/SettingsWindowUITests \
    -only-testing:agentGuiUITests/ChatFlowUITests \
    -only-testing:agentGuiUITests/ToolCallUITests \
    -only-testing:agentGuiUITests/WorkflowRecoveryUITests

# 或直接执行收敛后的冒烟脚本
./scripts/run_quality_smoke.sh

# 只跑单元 / 集成场景
./scripts/run_quality_smoke.sh unit

# 只跑 UI 冒烟
./scripts/run_quality_smoke.sh ui

# 对 UI 冒烟做 5 次可重复采样，并生成 markdown 报告
./scripts/sample_quality_baseline.sh ui 5

# 对单元 / 集成冒烟做 5 次可重复采样
./scripts/sample_quality_baseline.sh unit 5
```

更完整的测试矩阵和当前性能基线见：

- `docs/quality/test-matrix-2026-03-11.md`
- `docs/quality/performance-baseline-2026-03-11.md`

VS Code 里也可以直接运行 `Quality Smoke`、`Sample UI Baseline`、`Sample Unit Baseline` tasks。

仓库还提供了 GitHub Actions workflow：`.github/workflows/quality-smoke.yml`。

## 配置

首次运行时，通过主窗口右上角的设置按钮或系统菜单中的“设置...”打开独立设置窗口，并按分类完成配置：

1. 在“连接”中配置 Anthropic API Key、Base URL、模型和代理
2. 在“工具”中启用 Bash、Web Search、Web Fetch 和 LSP
3. 在“智能”中调整 Extended Thinking 与反思阈值
4. 在“记忆”中启用统一记忆运行时、治理层和长期记忆编辑器
5. 在“通用”中调整主题与查看版本、连接状态
6. 如需小说写作支持，继续在主窗口的相关工作流中启用创作记忆并绑定当前会话

## 架构

### Agentic Loop

agentGui 的核心是 **Agentic Loop** —— 一个多轮执行循环，让 Claude 能够自主调用工具、观察结果并持续迭代，直到任务完成。

```mermaid
flowchart TB
    Start([用户输入]) --> History[消息历史 Context]
    History --> API[Claude API Streaming]

    API --> Parse[解析响应]

    Parse --> Text[累积文本内容]
    Parse --> HasTools{有工具调用?}

    HasTools -->|Yes| Tools[工具调用列表]
    HasTools -->|No| End([结束循环])

    Tools --> Execute[逐个执行工具]
    Execute --> Collect[收集结果 更新历史]
    Collect --> History

    classDef process fill:#e1f5fe,stroke:#01579b
    classDef decision fill:#fff9c4,stroke:#f57f17
    classDef terminal fill:#e8f5e9,stroke:#2e7d32

    class History,API,Parse,Tools,Execute,Collect process
    class HasTools decision
    class Start,End terminal
```

**核心特性：**
- **流式处理**：实时解析 SSE 事件流，增量更新 UI
- **思考支持**：Claude 3.7+ 的 Extended Thinking 内容单独显示
- **上下文压缩**：当使用率超过 75% 时自动压缩历史消息
- **Token 监控**：实时追踪输入/输出 token 数量和成本

### 子代理系统

主 Agent 可以将任务委派给专业子代理，每个子代理有独立的系统提示、工具集和最大轮次限制。

| 子代理 | 描述 | 工具 | 用途 |
|--------|------|------|------|
| `planner` | 规划师 | 只读 | 分析任务需求，输出结构化执行计划 |
| `explorer` | 探索者 | 只读 + Web | 信息探索、代码库分析、资料汇总 |
| `coder` | 编写者 | 读写 + Bash | 实现代码变更，可运行命令验证 |
| `reviewer` | 审查者 | 只读 | 代码质量、安全性、规范性审查 |
| `executor` | 执行者 | Bash | 运行构建、测试、脚本等命令 |
| `summarizer` | 总结员 | 只读 | 读取文件/文档，生成简洁总结 |
| `writer` | 写作者 | 读写 + Bash | 专业写作辅助：生成、润色、翻译 |
| `outline_planner` | 大纲规划师 | 只读 | 文档结构规划、章节组织 |

**委派流程：**
1. 主 Agent 调用 `run_subagent` 工具
2. 系统创建独立的嵌套 Loop，传入子代理专用配置
3. 子代理运行（无递归，限制轮次）
4. 返回结果文本给主 Agent

### 工具系统

agentGui 通过工具扩展 Claude 的能力：

| 工具 | 功能 |
|------|------|
| `str_replace_based_edit_tool` | 文件查看、创建、编辑、插入 |
| `bash` | 受管终端任务运行时，支持命令分类、交互 prompt 接管与后台任务状态跟踪 |
| `web_search` | Web 搜索（Bing / inference.sh） |
| `web_fetch` | 网页内容抓取与清理 |
| `analyze_image` | 本地图片文件分析（Vision API） |
| `read_pdf` | PDF 文本提取 |
| `ask_user_question` | 结构化用户交互（暂停 Loop） |
| `update_todo_list` | 任务列表管理 |
| `memory_write` | 长期记忆写入 |
| `read_skill` | 技能内容加载 |
| `run_subagent` | 子代理委派 |

### Bash 受管终端

`bash` 工具当前基于持久 `zsh` session 提供受管终端任务运行时。运行前会先做命令分类，运行中会持续轮询输出和进程状态，并将结果归纳为结构化任务状态，再同步到时间线和工具调用 UI。

当前已落地的输入字段包括：

- `command`
- `task_id`
- `execution_mode`: `auto | foreground | background | interactive`
- `input`
- `signal`: `interrupt | terminate`
- `goal_hint`
- `scan_policy`: `adaptive | manual`
- `auto_reply_policy`: `safeOnly | disabled`
- 兼容旧字段：`background`、`interactive`、`interrupt`

当前自动处理的 prompt 类型包括：

- yes/no 确认：按安全默认值自动回复
- `Press Enter to continue`：自动发送回车
- 密码等敏感输入：不会自动回复，会升级为结构化用户决策
- 覆盖/删除等破坏性确认：不会自动确认，会升级为结构化用户决策

当前 UI 会为 bash 工具调用展示执行模式、任务状态、最近一次 agent 自动动作，并在详情中展示命令、状态摘要、prompt 摘要、agent 输入记录与输出片段。

当前限制：该实现仍基于 `Process + Pipe + sentinel`，不是 PTY 终端，因此不保证 `vim`、`less`、`top`、`fzf` 等全屏或强终端依赖程序可稳定工作；`ask_user_question` 目前也只支持结构化选项，不支持将敏感自由文本直接回填到终端 prompt。

### 创作记忆

创作记忆是独立于 `memory.md` 的项目级结构化记忆层，适合长篇小说、世界观设定和连续性敏感的写作任务。

- **作用范围**：围绕 `WritingProject` 保存角色卡、世界规则、章节、场景、时间线、伏笔和连续性问题
- **启用方式**：在设置页打开「启用创作记忆」，然后创建创作项目并把当前会话绑定到该项目
- **Prompt 注入**：运行时会根据当前请求自动拼装活跃角色、相关规则、最近事件和未解决伏笔，而不是把整个项目全文塞进上下文
- **与长期记忆的区别**：`memory_write` 面向全局偏好和跨任务经验；创作记忆只保存故事 canon，不写入 `~/.agentgui/memory.md`

### 统一记忆运行时

统一记忆运行时是当前正在迁移中的新读路径，用于把分散的记忆源收敛到一个最小相关切片里，再注入主 Agent loop。

- **当前已完成**：Memory Layer / Kind / Scope 核心模型、Creative/Coding/User Preferences profile、task/session/project unified records、Retrieval Planner、Prompt Assembler、Runtime Coordinator、主 loop 统一 read path、任务记忆 direct unified write path、基础治理规则与设置开关
- **当前状态**：TaskMemory 主链路已切到 unified store；`TaskMemoryService` / `TaskMemoryStoreAdapter` 已移除。`memory_write` 通过统一记忆运行时写入与治理，统一运行时目前负责统一读取、组装和部分写入治理
- **当前用户可见项**：设置页可以启用统一记忆运行时和治理层；启用后，聊天页会显示运行时已启用；工具调用详情会显示命中的 profiles、layers 和 warnings（若本轮有记录）；若存在运行时快照，还可以直接打开本轮记忆上下文面板，查看入选记录、排除原因、预算明细和占比图表
- **当前未完成**：后台巩固、归档、TTL、冲突治理面板、完整长期写回编排

当前内置的创作记忆工具包括：


## 项目结构

```
agentGui/
├── Models/                         # SwiftData 数据模型
│   ├── Session.swift                  # 对话会话
│   ├── Message.swift                  # 聊天消息
│   ├── ToolCall.swift                 # 工具调用记录
│   ├── AgentRound.swift               # Agent 执行轮次
│   ├── AgentMessage.swift             # 子代理消息
│   ├── AgentLoopPhase.swift           # 循环阶段枚举
│   ├── AppSettings.swift              # 应用设置
│   ├── SubagentDefinition.swift       # 子代理定义
│   ├── TodoItem.swift                 # 待办事项
│   ├── ExecutionPlan.swift            # 执行计划
│   ├── AttachedFile.swift             # 文件附件
│   ├── Skill.swift                    # 技能定义
│   └── Enums.swift                    # 枚举定义
│
├── Views/                          # SwiftUI 视图
│   ├── MainSplitView.swift             # 主界面（三栏布局）
│   ├── ChatView.swift                  # 聊天界面
│   ├── ChatView+*.swift                # 聊天界面扩展
│   ├── SessionListView.swift           # 会话列表
│   ├── SettingsView.swift              # 设置界面（隐式）
│   ├── TimelineView.swift              # 执行时间线（隐式）
│   ├── Editor/                         # 块编辑器
│   │   ├── BlockEditorModels.swift     # 块编辑器模型
│   │   ├── BlockMarkdownCodec.swift    # Markdown 编解码
│   │   ├── BlockDocumentEditor.swift   # 文档编辑器
│   │   ├── BlockTextEditor.swift       # 文本块编辑器
│   │   ├── BlockTableEditor.swift      # 表格块编辑器
│   │   ├── BlockRowView.swift          # 块行视图
│   │   ├── SlashCommandMenu.swift      # 斜杠命令菜单
│   │   ├── InlineStyleToolbarView.swift # 行内样式工具栏
│   │   └── BlockEditor*.swift          # 其他编辑器组件
│   ├── MessageBubbleView.swift         # 消息气泡
│   ├── ThinkingBubbleView.swift        # 思考气泡
│   ├── ToolCallBubbleView.swift        # 工具调用气泡
│   ├── AskUserQuestionView.swift       # 用户问题视图
│   ├── SubagentTimelineView.swift      # 子代理时间线
│   ├── TodoListView.swift              # 待办列表视图
│   ├── ArtifactDrawerView.swift        # Artifact 抽屉
│   └── [其他组件视图...]
│
├── Services/                       # 业务逻辑
│   ├── ClaudeService+AgenticLoop.swift # Agentic Loop 实现
│   ├── ClaudeService+Subagent.swift    # 子代理系统
│   ├── ClaudeService+ToolDispatch.swift # 工具分发
│   ├── ClaudeService+TextEditorTool.swift # 文件编辑工具
│   ├── ClaudeService+WebTools.swift    # Web 工具
│   ├── ClaudeService+MediaTools.swift  # 媒体工具
│   ├── ClaudeService+ContextCompression.swift # 上下文压缩
│   ├── ClaudeService+DynamicContent.swift # 动态内容
│   ├── ClaudeService+ToolBuilder.swift # 工具构建器
│   ├── BashSession.swift               # Shell 会话管理
│   ├── SkillService.swift              # 技能加载器
│   └── ACPClientService.swift          # ACP 客户端服务
│
├── Repositories/                   # 数据访问层
│   └── ...
│
└── Utilities/                      # 工具类和错误类型
    ├── WorkspaceState.swift            # 工作区状态
    ├── ConfigDirectoryManager.swift    # 配置目录管理
    └── ...
```

## 技术栈

- **Swift 6.0+** - 采用最新 Swift 语言特性（并发、发送性检查）
- **SwiftUI** - 声明式 UI 框架
- **SwiftData** - Apple 原生持久化框架
- **SwiftAnthropic** - Anthropic Claude API SDK
- **STTextView / STTextKitPlus** - 高性能文本编辑组件
- **BeautifulMermaid** - Mermaid 图表渲染

## 核心功能

### 块编辑器 (Block Editor)

类似 Notion 的现代化文档编辑器，支持：

- **16+ 种块类型**：段落、标题、引用、列表、待办、代码、表格、图片、链接、文件附件、提示块、折叠块等
- **斜杠命令**：输入 `/` 快速插入任意块类型，支持模糊搜索
- **行内样式**：选中文字后显示工具栏，支持加粗、斜体、删除线、行内代码
- **Markdown 双向转换**：自动解析和生成标准 Markdown 格式
- **高性能**：基于 NSTextView 的原生实现，支持大文件编辑

## 依赖管理

项目使用 Swift Package Manager 管理依赖：

| 依赖 | 版本 | 用途 |
|------|------|------|
| SwiftAnthropic | 2.2.1 | Anthropic Claude API SDK |
| STTextView | 2.3.5 | 高性能文本编辑组件 |
| BeautifulMermaid | 0.1.1 | Mermaid 图表渲染 |

## 内存目录

agentGui 在 `~/.claude/` 下存储用户数据：

```
~/.claude/
├── projects/
│   └── [项目名称]/
│       └── memory/    # 项目记忆文件
└── skills/            # 自定义技能目录
```

说明：上述目录用于长期记忆与技能。创作记忆的小说项目数据保存在应用的 SwiftData 存储中，不复用项目 `memory/` 目录。

## License

MIT License

## 作者

@feint

## 致谢

- [Anthropic](https://www.anthropic.com) - Claude API
- [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) - Swift SDK
- [STTextView](https://github.com/krzyzanowskim/STTextView) - 高性能文本编辑组件
- [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift) - Mermaid 图表渲染
- [Claude Code](https://claude.ai/code) - 技能系统设计灵感

## 开发状态

当前分支: `001-ai-agent-client`

项目正在积极开发中，核心功能已基本完成，正在完善块编辑器和子代理系统。
