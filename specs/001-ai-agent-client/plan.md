# 实现计划: AI Agent 客户端

**分支**: `001-ai-agent-client` | **日期**: 2026-02-10 | **规格**: [spec.md](./spec.md)
**输入**: 来自 `/specs/001-ai-agent-client/spec.md` 的功能规格

## 概要

构建一个功能完整的 macOS AI Agent 客户端应用，通过 Agent Client Protocol (ACP) 与多种 AI 编程代理（如 Claude Code、OpenCode）通信。应用支持本地 stdio 和远程 WebSocket 连接，提供实时对话界面、权限管理、会话历史持久化等功能。

技术方案使用 swift-acp SDK（已引入），采用 SwiftUI 构建原生 macOS 界面，SwiftData 进行数据持久化。应用遵循 MVVM 架构，模块化设计以支持未来扩展。

## 技术上下文

**Language/Version**: Swift 6.0+
**Primary Dependencies**: swift-acp (ACP, ACPModel, ACPHTTP, ACPRegistry)
**Storage**: SwiftData (ModelContainer + ModelContext)
**Testing**: XCTest
**Target Platform**: macOS 26.0+
**Project Type**: macOS SwiftUI 应用
**Performance Goals**: 60fps UI 渲染，启动时间 < 2秒，响应延迟 < 100ms
**Constraints**: Swift 6 严格并发检查，禁用强制解包
**Scale/Scope**: 支持 10+ 并发会话，单会话 1000+ 消息历史

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

参考 `.specify/memory/constitution.md` 中的核心原则：

- [x] **模块化架构**：按功能模块组织（Agent管理、会话、消息、权限、设置），模块间通过明确接口通信
- [x] **第三方库优先**：使用成熟库 swift-acp 实现 ACP 协议，避免重复造轮子
- [x] **SwiftUI & HIG**：使用 SwiftUI 构建，遵循 macOS 原生交互模式（工具栏、侧边栏、对话框）
- [x] **SwiftData**：所有持久化数据使用 SwiftData 存储（Agent配置、会话、消息、权限记录、设置）
- [x] **代码质量**：采用 MVVM 模式，使用 async/await 和 Actor 确保并发安全

**无违规项，无需 Complexity Tracking**

## 项目结构

### 文档 (此功能)

```text
specs/001-ai-agent-client/
├── plan.md              # 本文件
├── research.md          # 技术研究和决策
├── data-model.md        # SwiftData 数据模型设计
├── quickstart.md        # 快速开始指南
├── contracts/           # 模块间接口契约
└── tasks.md             # 实现任务列表 (由 /speckit.tasks 生成)
```

### 源代码 (仓库根目录)

```text
agentGui/                        # 主应用目录
├── agentGuiApp.swift           # 应用入口
├── Models/                     # SwiftData 模型
│   ├── AgentConfiguration.swift
│   ├── Session.swift
│   ├── Message.swift
│   ├── ToolCall.swift
│   ├── PermissionRequest.swift
│   └── AppSettings.swift
├── ViewModels/                 # 视图模型
│   ├── AgentListViewModel.swift
│   ├── SessionViewModel.swift
│   ├── ChatViewModel.swift
│   └── SettingsViewModel.swift
├── Views/                      # SwiftUI 视图
│   ├── AgentListView.swift
│   ├── SessionListView.swift
│   ├── ChatView.swift
│   ├── PermissionDialog.swift
│   └── SettingsView.swift
├── Services/                   # 业务逻辑服务
│   ├── ACPClientService.swift  # 封装 swift-acp Client
│   ├── AgentLifecycleService.swift
│   ├── SessionManager.swift
│   └── PermissionManager.swift
├── Repositories/               # 数据访问抽象层
│   ├── AgentRepository.swift
│   ├── SessionRepository.swift
│   └── MessageRepository.swift
├── Utilities/                  # 工具类
│   ├── ACPAdapters.swift       # ACP 类型到应用模型的适配器
│   └── Extensions.swift
└── Resources/                  # 资源文件
    └── Assets.xcassets/

agentGuiTests/                  # 单元测试
├── ModelTests/
├── ServiceTests/
└── ViewModelTests/

agentGuiUITests/                # UI 测试
```

**Structure Decision**: 采用标准 macOS SwiftUI 应用结构，按功能模块组织。Services 层封装 swift-acp 的复杂性，Repositories 层隔离 SwiftData 实现细节，ViewModels 处理 UI 状态和业务逻辑。

## 研究阶段 (Phase 0) 输出

详见 [research.md](./research.md)

## 数据模型设计 (Phase 1) 输出

详见 [data-model.md](./data-model.md)

## 模块契约 (Phase 1) 输出

详见 [contracts/](./contracts/)

## 快速开始指南 (Phase 1) 输出

详见 [quickstart.md](./quickstart.md)
