---

description: "Task list template for feature implementation"
---

# Tasks: [FEATURE NAME]

**Input**: Design documents from `/specs/[###-feature-name]/`
**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md, contracts/

**Tests**: The examples below include test tasks. Tests are OPTIONAL - only include them if explicitly requested in the feature specification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **macOS SwiftUI 应用**: `agentGui/` 目录下按功能模块组织
- **Views**: `agentGui/Views/` 或 `agentGui/Features/[功能名]/Views/`
- **ViewModels**: `agentGui/ViewModels/` 或 `agentGui/Features/[功能名]/ViewModels/`
- **Models**: `agentGui/Models/`
- **Services**: `agentGui/Services/`
- **Repositories**: `agentGui/Repositories/`
- **Tests**: `agentGuiTests/` (单元测试), `agentGuiUITests/` (UI 测试)

<!-- 
  ============================================================================
  IMPORTANT: The tasks below are SAMPLE TASKS for illustration purposes only.
  
  The /speckit.tasks command MUST replace these with actual tasks based on:
  - User stories from spec.md (with their priorities P1, P2, P3...)
  - Feature requirements from plan.md
  - Entities from data-model.md
  - Endpoints from contracts/
  
  Tasks MUST be organized by user story so each story can be:
  - Implemented independently
  - Tested independently
  - Delivered as an MVP increment
  
  DO NOT keep these sample tasks in the generated tasks.md file.
  ============================================================================
-->

## Phase 1: 项目初始化 (Shared Infrastructure)

**目的**: 项目初始化和基础结构搭建

- [ ] T001 创建项目目录结构（按功能模块组织）
- [ ] T002 配置 Swift Package Manager 依赖
- [ ] T003 [P] 配置 SwiftLint 代码规范检查
- [ ] T004 [P] 启用 Swift 6 严格并发检查

---

## Phase 2: 基础设施 (Blocking Prerequisites)

**目的**: 所有用户故事实现前必须完成的核心基础设施

**⚠️ 关键**: 在此阶段完成前，不得开始任何用户故事的实现

根据项目调整的基础任务：

- [ ] T005 配置 SwiftData ModelContainer 和 ModelContext
- [ ] T006 [P] 创建 Repository 抽象层基础协议
- [ ] T007 [P] 配置错误处理和日志记录基础设施
- [ ] T008 创建所有用户故事依赖的共享数据模型
- [ ] T009 [P] 创建通用 SwiftUI 组件库（如适用）

**检查点**: 基础设施就绪 - 用户故事实现可以并行开始

---

## Phase 3: 用户故事 1 - [标题] (优先级: P1) 🎯 MVP

**目标**: [简要描述此用户故事交付的内容]

**独立测试**: [如何独立验证此功能]

### 用户故事 1 测试 (可选 - 仅在功能规格明确要求时) ⚠️

> **注意**: 如有测试，先编写并确保其失败，再开始实现

- [ ] T010 [P] [US1] [实体名] 模型单元测试 in agentGuiTests/ModelTests/[ModelName]Tests.swift
- [ ] T011 [P] [US1] [服务名] 单元测试 in agentGuiTests/ServiceTests/[ServiceName]Tests.swift

### 用户故事 1 实现

- [ ] T012 [P] [US1] 创建 [Entity] SwiftData 模型 in agentGui/Models/[Entity].swift
- [ ] T013 [P] [US1] 创建 [Repository] in agentGui/Repositories/[Repository].swift
- [ ] T014 [US1] 实现 [Service] in agentGui/Services/[Service].swift (依赖 T012, T013)
- [ ] T015 [US1] 创建 [ViewModel] in agentGui/ViewModels/[ViewModel].swift (依赖 T014)
- [ ] T016 [US1] 实现 [View] in agentGui/Views/[View].swift (依赖 T015)
- [ ] T017 [US1] 添加动效和交互优化

**检查点**: 此时，用户故事 1 应完全可用且可独立测试

---

## Phase 4: 用户故事 2 - [标题] (优先级: P2)

**目标**: [简要描述此用户故事交付的内容]

**独立测试**: [如何独立验证此功能]

### 用户故事 2 测试 (可选)

- [ ] T018 [P] [US2] [实体/服务] 单元测试 in agentGuiTests/[目录]/[文件名]Tests.swift

### 用户故事 2 实现

- [ ] T020 [P] [US2] 创建/扩展 [Entity] 模型 in agentGui/Models/[Entity].swift
- [ ] T021 [US2] 实现/扩展 [Service] in agentGui/Services/[Service].swift
- [ ] T022 [US2] 创建 [ViewModel] in agentGui/ViewModels/[ViewModel].swift
- [ ] T023 [US2] 实现 [View] in agentGui/Views/[View].swift
- [ ] T024 [US2] 与用户故事 1 组件集成（如需要）

**检查点**: 此时，用户故事 1 和 2 都应独立可用

---

## Phase 5: 用户故事 3 - [标题] (优先级: P3)

**目标**: [简要描述此用户故事交付的内容]

**独立测试**: [如何独立验证此功能]

### 用户故事 3 实现

- [ ] T025 [P] [US3] 创建/扩展 [Entity] 模型
- [ ] T026 [US3] 实现/扩展 [Service]
- [ ] T027 [US3] 创建 [ViewModel]
- [ ] T028 [US3] 实现 [View]

**检查点**: 所有用户故事应独立可用

---

[根据需要添加更多用户故事阶段，遵循相同模式]

---

## Phase N: 打磨与横切关注点

**目的**: 影响多个用户故事的优化

- [ ] TXXX [P] 更新中文文档
- [ ] TXXX 代码清理和重构
- [ ] TXXX 性能优化（保持 60fps）
- [ ] TXXX [P] 补充单元测试 in agentGuiTests/
- [ ] TXXX 深色/浅色模式适配验证
- [ ] TXXX 运行 quickstart.md 验证（如适用）

---

## 依赖与执行顺序

### 阶段依赖

- **初始化 (Phase 1)**: 无依赖 - 可立即开始
- **基础设施 (Phase 2)**: 依赖初始化完成 - 阻塞所有用户故事
- **用户故事 (Phase 3+)**: 全部依赖基础设施阶段完成
  - 可并行开发（如有资源）
  - 或按优先级顺序进行（P1 → P2 → P3）
- **打磨 (最终阶段)**: 依赖所有预期用户故事完成

### 用户故事依赖

- **用户故事 1 (P1)**: 基础设施完成后可开始 - 无其他故事依赖
- **用户故事 2 (P2)**: 基础设施完成后可开始 - 可与 US1 集成但应独立可测
- **用户故事 3 (P3)**: 基础设施完成后可开始 - 可与 US1/US2 集成但应独立可测

### 单个用户故事内

- 测试（如有）MUST 先编写并确保失败
- Models → Repositories → Services → ViewModels → Views
- 核心实现优先于集成
- 故事完成后方可进入下一优先级

### 并行机会

- 所有初始化阶段标记 [P] 的任务可并行
- 所有基础设施阶段标记 [P] 的任务可并行
- 基础设施完成后，所有用户故事可并行开始
- 单个故事内标记 [P] 的任务可并行

---

## 实现策略

### MVP 优先（仅用户故事 1）

1. 完成初始化阶段
2. 完成基础设施阶段（关键 - 阻塞所有故事）
3. 完成用户故事 1
4. **停止并验证**: 独立测试用户故事 1
5. 如就绪则部署/演示

### 增量交付

1. 完成初始化 + 基础设施 → 基础就绪
2. 添加用户故事 1 → 独立测试 → 部署/演示 (MVP!)
3. 添加用户故事 2 → 独立测试 → 部署/演示
4. 添加用户故事 3 → 独立测试 → 部署/演示
5. 每个故事增加价值且不破坏已有功能

---

## 注意事项

- [P] 任务 = 不同文件，无依赖
- [Story] 标签将任务映射到特定用户故事
- 每个用户故事应可独立完成和测试
- 确保测试在实现前失败
- 每个任务或逻辑组后提交
- 在任何检查点停止以独立验证故事
- 避免：模糊任务、同文件冲突、破坏独立性的跨故事依赖
