# agentGui

一个现代化的 macOS 原生 AI Agent 客户端，基于 Anthropic Claude API 构建。

## 特性

- **原生 macOS 体验** - 使用 SwiftUI 构建，完美适配 macOS 设计语言
- **Claude API 集成** - 支持所有 Claude 模型（Opus 4.6、Sonnet 4.6、Haiku 4.5 等）
- **多会话管理** - 创建和管理多个对话会话，历史记录本地持久化
- **Agentic Loop** - 完整的多轮工具调用循环，支持复杂任务分解与执行
- **子代理协作** - 内置 8 种专业子代理，支持任务委派和协作
- **工具生态** - 文件编辑、Bash 执行、Web 搜索、图片分析、PDF 读取等
- **技能系统** - 扩展 AI 能力的自定义技能，兼容 Claude Code 技能格式
- **长期记忆** - 在 `~/.agentgui/memory.md` 中持久化跨会话的知识
- **Extended Thinking** - 支持 Claude 3.7+ 的深度推理模式
- **流式响应** - 实时显示 AI 回复，支持 Markdown 渲染
- **Timeline 视图** - 可视化展示 Agent 执行过程和工具调用链

## 系统要求

- macOS 14.0+
- Xcode 16.0+
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

## 配置

首次运行时，在「设置」标签页中：

1. 配置 Anthropic API Key（从 [console.anthropic.com](https://console.anthropic.com) 获取）
2. （可选）设置自定义 Base URL 用于兼容代理服务
3. 选择要使用的 Claude 模型
4. 根据需要启用工具和技能

## 架构

### Agentic Loop

agentGui 的核心是 **Agentic Loop** —— 一个多轮执行循环，让 Claude 能够自主调用工具、观察结果并持续迭代，直到任务完成。

```
┌─────────────────────────────────────────────────────────────┐
│                    Agentic Loop                              │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────┐    ┌─────────────┐    ┌──────────────┐        │
│  │  用户   │───▶│  消息历史   │───▶│ Claude API   │        │
│  │  输入   │    │  (context)  │    │  (streaming) │        │
│  └─────────┘    └─────────────┘    └──────┬───────┘        │
│                                              │                │
│                                        ┌─────▼─────┐        │
│                                        │  解析响应  │        │
│                                        └─────┬─────┘        │
│                                              │                │
│                    ┌─────────────────────────┼────────────┐  │
│                    │                         │            │  │
│            ┌───────▼───────┐       ┌────────▼────────┐    │  │
│            │  累积文本内容  │       │   工具调用列表   │    │  │
│            └───────────────┘       └────────┬────────┘    │  │
│                                             │             │  │
│                                     ┌───────▼───────┐     │  │
│                                     │  逐个执行工具  │     │  │
│                                     └───────┬───────┘     │  │
│                                             │             │  │
│                                    ┌────────▼────────┐    │  │
│                                    │   收集结果      │    │  │
│                                    │   更新历史      │    │  │
│                                    └────────┬────────┘    │  │
│                                             │             │  │
│                                       有工具调用?          │  │
│                                             │             │  │
│                                    ┌────────▼────────┐    │  │
│                                    │     YES         │    │  │
│                                    │  继续下一轮 ─────┼────┘  │
│                                    └────────┬────────┘       │
│                                             │                │
│                                    ┌────────▼────────┐       │
│                                    │     NO          │       │
│                                    │  结束循环        │       │
│                                    └─────────────────┘       │
│                                                               │
└─────────────────────────────────────────────────────────────┘
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
| `bash` | 持久化 Shell 会话，支持工作目录 |
| `web_search` | Web 搜索（Bing / inference.sh） |
| `web_fetch` | 网页内容抓取与清理 |
| `analyze_image` | 本地图片文件分析（Vision API） |
| `read_pdf` | PDF 文本提取 |
| `ask_user_question` | 结构化用户交互（暂停 Loop） |
| `update_todo_list` | 任务列表管理 |
| `memory_write` | 长期记忆写入 |
| `read_skill` | 技能内容加载 |
| `run_subagent` | 子代理委派 |

## 项目结构

```
agentGui/
├── Models/                         # SwiftData 数据模型
│   ├── Session.swift                  # 对话会话
│   ├── Message.swift                  # 聊天消息
│   ├── ToolCall.swift                 # 工具调用记录
│   ├── AgentRound.swift               # Agent 执行轮次
│   ├── AppSettings.swift              # 应用设置
│   ├── SubagentDefinition.swift       # 子代理定义
│   ├── TodoItem.swift                 # 待办事项
│   ├── ExecutionPlan.swift            # 执行计划
│   └── Enums.swift                    # 枚举定义
│
├── Views/                          # SwiftUI 视图
│   ├── MainSplitView.swift             # 主界面（三栏布局）
│   ├── ChatView.swift                  # 聊天界面
│   ├── SessionListView.swift           # 会话列表
│   ├── SettingsView.swift              # 设置界面
│   ├── TimelineView.swift              # 执行时间线
│   └── Components/                     # UI 组件
│
├── Services/                       # 业务逻辑
│   ├── ClaudeService.swift             # Claude API 核心服务
│   ├── ClaudeService+AgenticLoop.swift # Agentic Loop 实现
│   ├── ClaudeService+Subagent.swift    # 子代理系统
│   ├── ClaudeService+ToolDispatch.swift # 工具分发
│   ├── ClaudeService+TextEditorTool.swift # 文件编辑工具
│   ├── ClaudeService+WebTools.swift    # Web 工具
│   ├── ClaudeService+MediaTools.swift  # 媒体工具
│   ├── ClaudeService+ContextCompression.swift # 上下文压缩
│   ├── BashSession.swift               # Shell 会话管理
│   ├── SkillService.swift              # 技能加载器
│   └── SessionService.swift            # 会话管理
│
├── Repositories/                   # 数据访问层
│   └── ...
│
└── Utilities/                      # 工具类和错误类型
    └── ...
```

## 技术栈

- **Swift 6.0+** - 采用最新 Swift 语言特性（并发、发送性检查）
- **SwiftUI** - 声明式 UI 框架
- **SwiftData** - Apple 原生持久化框架
- **SwiftAnthropic** - Anthropic Claude API SDK
- **STTextView** - 高性能文本编辑组件
- **BeautifulMermaid** - Mermaid 图表渲染

## 依赖管理

项目使用 Xcode Package Manager 管理依赖：

```swift
// Package Dependencies
- SwiftAnthropic: https://github.com/mtuck/swift-anthropic.git
- STTextView: https://github.com/krzyzanowskim/STTextView.git
- BeautifulMermaid: https://github.com/yuheui/BeautifulMermaid.git
```

## 内存目录

agentGui 在 `~/.agentgui/` 下存储用户数据：

```
~/.agentgui/
├── memory.md          # 长期记忆文件
├── skills/            # 自定义技能目录
└── ...                # 其他配置
```

## License

MIT License

## 作者

@feint

## 致谢

- [Anthropic](https://www.anthropic.com) - Claude API
- [SwiftAnthropic](https://github.com/mtuck/swift-anthropic) - Swift SDK
- [Claude Code](https://claude.ai/code) - 技能系统设计灵感
