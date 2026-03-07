# agentGui

一个现代化的 macOS 原生 AI Agent 客户端，基于 Anthropic Claude API 构建。

## 特性

- **原生 macOS 体验** - 使用 SwiftUI 构建，完美适配 macOS 设计语言
- **Claude API 集成** - 支持所有 Claude 模型（Opus 4.6、Sonnet 4.6、Haiku 4.5 等）
- **多会话管理** - 创建和管理多个对话会话，历史记录本地持久化
- **工具支持** - 文件读写、Bash 命令执行、Web 搜索、网页抓取
- **技能系统** - 扩展 AI 能力的自定义技能，支持 Claude Code 技能生态
- **子代理协作** - 内置 explorer、coder、reviewer、executor、summarizer 等专业子代理
- **长期记忆** - 在 `~/.agentgui/memory.md` 中持久化跨会话的知识
- **Extended Thinking** - 支持 Claude 3.7+ 的深度推理模式
- **流式响应** - 实时显示 AI 回复，支持 Markdown 渲染

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

## 项目结构

```
agentGui/
├── Models/              # SwiftData 数据模型
│   ├── Session.swift      # 对话会话
│   ├── Message.swift      # 聊天消息
│   ├── ToolCall.swift     # 工具调用记录
│   └── AppSettings.swift  # 应用设置
├── Views/               # SwiftUI 视图
│   ├── MainSplitView.swift    # 主界面
│   ├── ChatView.swift         # 聊天界面
│   ├── SessionListView.swift  # 会话列表
│   └── SettingsView.swift     # 设置界面
├── Services/            # 业务逻辑
│   ├── ClaudeService+*.swift  # Claude API 封装
│   ├── BashSession.swift      # Shell 会话管理
│   └── SkillService.swift     # 技能加载器
├── Repositories/        # 数据访问层
└── Utilities/           # 工具类和错误类型
```

## 技术栈

- **Swift 6.0+** - 采用最新 Swift 语言特性
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

## 许可证

MIT License

## 作者

@feint

## 致谢

- [Anthropic](https://www.anthropic.com) - Claude API
- [SwiftAnthropic](https://github.com/mtuck/swift-anthropic) - Swift SDK
