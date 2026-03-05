# Tasks: AI Agent 客户端

**Input**: Design documents from `/specs/001-ai-agent-client/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: 功能规格未明确要求测试，测试任务为可选

**Organization**: 任务按用户故事分组，以支持每个故事的独立实现和测试

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行执行（不同文件，无依赖）
- **[Story]**: 任务所属用户故事（US1, US2, US3 等）
- 包含精确的文件路径

## Path Conventions

- **macOS SwiftUI 应用**: `agentGui/` 目录下按功能模块组织
- **Views**: `agentGui/Views/`
- **ViewModels**: `agentGui/ViewModels/`
- **Models**: `agentGui/Models/`
- **Services**: `agentGui/Services/`
- **Repositories**: `agentGui/Repositories/`
- **Utilities**: `agentGui/Utilities/`

---

## Phase 1: 项目初始化 (Shared Infrastructure)

**目的**: 项目初始化和基础结构搭建

- [ ] T001 创建项目目录结构 in agentGui/{Models,Views,ViewModels,Services,Repositories,Utilities}
- [ ] T002 验证 swift-acp SPM 依赖配置 in agentGui.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
- [ ] T003 [P] 配置 Swift 6 严格并发检查 in Xcode build settings (Swift Compiler - Language Modes)
- [ ] T004 [P] 更新应用入口文件 agentGuiApp.swift 支持多 Model in agentGui/agentGuiApp.swift

---

## Phase 2: 基础设施 (Blocking Prerequisites)

**目的**: 所有用户故事实现前必须完成的核心基础设施

**⚠️ 关键**: 在此阶段完成前，不得开始任何用户故事的实现

- [ ] T005 配置 SwiftData ModelContainer 包含所有模型 in agentGui/agentGuiApp.swift
- [ ] T006 [P] 创建应用错误类型定义 in agentGui/Utilities/AgentClientError.swift
- [ ] T007 [P] 创建 Repository 基础协议 in agentGui/Repositories/RepositoryProtocols.swift
- [ ] T008 创建所有 SwiftData 数据模型枚举 (AgentType, ConnectionType, SessionMode, MessageDirection, ContentType, MessageStatus, ToolKind, ToolStatus, PermissionType, PermissionDecision, ThemeMode, AutoApprovePolicy) in agentGui/Models/Enums.swift
- [ ] T009 [P] 创建 ACP 类型适配器工具类 in agentGui/Utilities/ACPAdapters.swift

**检查点**: 基础设施就绪 - 用户故事实现可以并行开始

---

## Phase 3: 用户故事 1 - 连接和管理 Agent (优先级: P1) 🎯 MVP

**目标**: 用户能够添加、配置和启动 AI Agent 服务，建立与 Agent 的通信会话

**独立测试**: 启动本地 Agent（如 Claude Code）并成功创建会话，验证 Agent 显示为已连接状态

### 用户故事 1 实现

- [ ] T010 [P] [US1] 创建 AgentConfiguration SwiftData 模型 in agentGui/Models/AgentConfiguration.swift
- [ ] T011 [P] [US1] 创建 AppSettings SwiftData 模型 in agentGui/Models/AppSettings.swift
- [ ] T012 [P] [US1] 创建 AgentRepository 实现数据访问 in agentGui/Repositories/AgentRepository.swift
- [ ] T013 [US1] 实现 ACPClientService Actor 封装 swift-acp Client in agentGui/Services/ACPClientService.swift (依赖 T009, T010)
- [ ] T014 [US1] 实现 AgentLifecycleService 管理 Agent 生命周期 in agentGui/Services/AgentLifecycleService.swift (依赖 T013)
- [ ] T015 [US1] 创建 AgentListViewModel @Observable 视图模型 in agentGui/ViewModels/AgentListViewModel.swift (依赖 T014)
- [ ] T016 [US1] 实现 AgentListView SwiftUI 视图 in agentGui/Views/AgentListView.swift (依赖 T015)
- [ ] T017 [US1] 实现 Agent 配置添加/编辑对话框 in agentGui/Views/AgentConfigSheet.swift (依赖 T016)

**检查点**: 此时用户可以添加 Agent、连接/断开 Agent，应用显示正确的连接状态

---

## Phase 4: 用户故事 2 - 发送提示并接收响应 (优先级: P1)

**目标**: 用户能够向 Agent 发送文本提示，并实时查看 Agent 的响应内容

**独立测试**: 连接 Agent，发送简单提示，验证响应正确显示

### 用户故事 2 实现

- [ ] T018 [P] [US2] 创建 Session SwiftData 模型 in agentGui/Models/Session.swift
- [ ] T019 [P] [US2] 创建 Message SwiftData 模型 in agentGui/Models/Message.swift
- [ ] T020 [P] [US2] 创建 ToolCall SwiftData 模型 in agentGui/Models/ToolCall.swift
- [ ] T021 [P] [US2] 创建 SessionRepository 实现数据访问 in agentGui/Repositories/SessionRepository.swift
- [ ] T022 [P] [US2] 创建 MessageRepository 实现数据访问 in agentGui/Repositories/MessageRepository.swift
- [ ] T023 [US2] 实现 SessionManager 管理会话生命周期 in agentGui/Services/SessionManager.swift (依赖 T013, T021)
- [ ] T024 [US2] 扩展 ACPClientService 添加发送提示和订阅更新功能 in agentGui/Services/ACPClientService.swift (依赖 T023)
- [ ] T025 [US2] 创建 ChatViewModel @Observable 视图模型 in agentGui/ViewModels/ChatViewModel.swift (依赖 T024)
- [ ] T026 [US2] 实现 ChatView SwiftUI 聊天界面 in agentGui/Views/ChatView.swift (依赖 T025)
- [ ] T027 [US2] 实现消息气泡视图组件 in agentGui/Views/MessageBubbleView.swift (依赖 T026)
- [ ] T028 [US2] 实现工具调用显示组件 in agentGui/Views/ToolCallView.swift (依赖 T026)

**检查点**: 此时用户可以发送提示，实时查看响应，包括流式文本和工具调用

---

## Phase 5: 用户故事 3 - 权限管理 (优先级: P2)

**目标**: 用户能够审查和批准 Agent 发起的敏感操作请求

**独立测试**: 发送需要文件访问的提示，验证权限对话框正确显示并处理用户决定

### 用户故事 3 实现

- [ ] T029 [P] [US3] 创建 PermissionRequest SwiftData 模型 in agentGui/Models/PermissionRequest.swift
- [ ] T030 [US3] 实现 PermissionManager Actor 处理权限请求 in agentGui/Services/PermissionManager.swift
- [ ] T031 [US3] 实现 ACPClientService 的 ClientDelegate 方法处理文件和终端请求 in agentGui/Services/ACPClientService.swift (依赖 T030)
- [ ] T032 [US3] 创建权限请求对话框 SwiftUI 视图 in agentGui/Views/PermissionDialog.swift (依赖 T031)
- [ ] T033 [US3] 集成权限对话框到 ChatView in agentGui/Views/ChatView.swift (依赖 T032)

**检查点**: Agent 请求敏感操作时显示权限对话框，用户决定正确传递回 Agent

---

## Phase 6: 用户故事 4 - 会话历史和项目管理 (优先级: P2)

**目标**: 用户能够创建多个会话，每个会话关联不同的工作目录，并能在会话间切换

**独立测试**: 创建两个不同工作目录的会话，切换会话验证历史独立

### 用户故事 4 实现

- [ ] T034 [P] [US4] 创建 SessionViewModel @Observable 视图模型 in agentGui/ViewModels/SessionViewModel.swift (依赖 T023)
- [ ] T035 [US4] 实现 SessionListView 会话列表视图 in agentGui/Views/SessionListView.swift (依赖 T034)
- [ ] T036 [US4] 实现新建会话对话框 in agentGui/Views/NewSessionSheet.swift (依赖 T035)
- [ ] T037 [US4] 实现会话切换逻辑连接 ChatView in agentGui/Views/ChatView.swift (依赖 T036)
- [ ] T038 [US4] 实现应用启动时恢复会话历史 in agentGui/agentGuiApp.swift (依赖 T022)

**检查点**: 用户可以创建/切换会话，历史独立保存和恢复

---

## Phase 7: 用户故事 5 - 设置和偏好 (优先级: P3)

**目标**: 用户能够配置应用偏好，包括主题、自动批准策略、Agent 默认参数

**独立测试**: 打开设置面板，修改配置验证生效

### 用户故事 5 实现

- [ ] T039 [P] [US5] 创建 SettingsViewModel @Observable 视图模型 in agentGui/ViewModels/SettingsViewModel.swift (依赖 T012)
- [ ] T040 [US5] 实现 SettingsView 设置界面 in agentGui/Views/SettingsView.swift (依赖 T039)
- [ ] T041 [US5] 实现主题切换逻辑 in agentGui/agentGuiApp.swift (依赖 T040)
- [ ] T042 [US5] 集成自动批准策略到 PermissionManager in agentGui/Services/PermissionManager.swift (依赖 T040)
- [ ] T043 [US5] 实现启动时自动连接逻辑 in agentGui/Services/AgentLifecycleService.swift (依赖 T040)

**检查点**: 设置面板功能正常，配置正确应用

---

## Phase 8: 用户故事 6 - Agent 注册表和发现 (优先级: P3)

**目标**: 用户能够浏览、搜索和安装来自 ACP 注册表的可用 Agent

**独立测试**: 打开 Agent 注册表面板，搜索并模拟安装 Agent

### 用户故事 6 实现

- [ ] T044 [P] [US6] 添加 ACPRegistry SPM 依赖 in Package.swift 或 Xcode
- [ ] T045 [US6] 实现 RegistryService 浏览和搜索 Agent in agentGui/Services/RegistryService.swift (依赖 T044)
- [ ] T046 [US6] 实现 AgentInstaller 安装 Agent in agentGui/Services/AgentInstaller.swift (依赖 T045)
- [ ] T047 [US6] 创建 AgentRegistryView 注册表面板 in agentGui/Views/AgentRegistryView.swift (依赖 T046)
- [ ] T048 [US6] 集成注册表面板到 AgentListView in agentGui/Views/AgentListView.swift (依赖 T047)

**检查点**: 用户可以浏览注册表，搜索并安装 Agent

---

## Phase 9: 打磨与横切关注点

**目的**: 影响多个用户故事的优化

- [ ] T049 [P] 实现 NavigationSplitView 三栏布局整合所有视图 in agentGui/Views/MainView.swift
- [ ] T050 添加工具栏和菜单栏 in agentGui/Views/MainWindowView.swift
- [ ] T051 [P] 优化消息列表性能使用 LazyVStack in agentGui/Views/ChatView.swift
- [ ] T052 实现深色/浅色模式完整适配 in agentGui/Views/
- [ ] T053 [P] 添加错误处理 Alert 和友好提示 in agentGui/Utilities/ErrorHandler.swift
- [ ] T054 实现启动优化确保启动时间 < 2秒 in agentGui/agentGuiApp.swift
- [ ] T055 验证 60fps UI 渲染性能 in agentGui/Views/
- [ ] T056 更新 README.md 中文使用文档 in README.md

---

## 依赖与执行顺序

### 阶段依赖

- **初始化 (Phase 1)**: 无依赖 - 可立即开始
- **基础设施 (Phase 2)**: 依赖初始化完成 - 阻塞所有用户故事
- **用户故事 (Phase 3-8)**: 全部依赖基础设施阶段完成
  - US1 和 US2 是 P1 优先级，应优先实现
  - US3 和 US4 是 P2 优先级，可并行开发
  - US5 和 US6 是 P3 优先级，最后实现
- **打磨 (Phase 9)**: 依赖所有预期用户故事完成

### 用户故事依赖

| 用户故事 | 依赖阶段 | 故事间依赖 |
|---------|---------|-----------|
| US1 (P1) | 基础设施 | 无，可独立实现 |
| US2 (P1) | 基础设施 + US1 | 依赖 ACPClientService (US1) |
| US3 (P2) | 基础设施 + US2 | 依赖 ACPClientService 扩展 (US2) |
| US4 (P2) | 基础设施 + US2 | 依赖 SessionManager (US2) |
| US5 (P3) | 基础设施 + US1 + US3 | 依赖 AgentRepository (US1), PermissionManager (US3) |
| US6 (P3) | 基础设施 + US1 | 依赖 AgentLifecycleService (US1) |

### 单个用户故事内

- 模型 (Models) → 仓库 (Repositories) → 服务 (Services) → 视图模型 (ViewModels) → 视图 (Views)
- 标记 [P] 的任务可并行执行
- 核心实现优先于集成

### 并行机会

**阶段内并行**:
- T003, T004 (初始化阶段)
- T006, T007, T009 (基础设施阶段)
- T010, T011 (US1 模型创建)
- T018, T019, T020 (US2 模型创建)
- T021, T022 (US2 仓库创建)

**用户故事并行** (基础设施完成后):
- US5 和 US6 可并行开发 (P3 优先级)
- US3 和 US4 可部分并行 (P2 优先级)

---

## 实现策略

### MVP 优先 (用户故事 1 + 2)

1. 完成初始化阶段 (T001-T004)
2. 完成基础设施阶段 (T005-T009)
3. 完成用户故事 1 (T010-T017): 连接和管理 Agent
4. 完成用户故事 2 (T018-T028): 发送提示并接收响应
5. **停止并验证**: 用户可以添加 Agent、连接、发送消息、查看响应
6. 如就绪则部署/演示

### 增量交付

1. 初始化 + 基础设施 → 基础就绪
2. 添加 US1 + US2 → 可演示 MVP (添加 Agent、对话)
3. 添加 US3 → 安全增强 (权限管理)
4. 添加 US4 → 体验增强 (多会话)
5. 添加 US5 → 个性化 (设置)
6. 添加 US6 → 易用性 (Agent 注册表)
7. 打磨 → 生产就绪

### 并行团队策略

如有多个开发者：

1. 团队共同完成初始化 + 基础设施
2. 基础设施完成后并行开发：
   - 开发者 A: US1 + US2 (核心功能)
   - 开发者 B: US3 + US4 (安全与会话)
   - 开发者 C: US5 + US6 (设置与注册表)
3. 最后合并并打磨

---

## 注意事项

- [P] 任务 = 不同文件，无依赖，可并行执行
- [Story] 标签将任务映射到特定用户故事
- 每个用户故事应可独立完成和测试
- 每个任务或逻辑组后提交代码
- 在任何检查点停止以独立验证故事
- 避免：模糊任务、同文件冲突、破坏独立性的跨故事依赖
