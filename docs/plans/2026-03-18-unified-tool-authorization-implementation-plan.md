# 统一工具授权架构实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为渠道新增整体工具权限控制，并把后台任务、远程渠道和后续执行主体统一切换到共享的工具授权架构，直接删除历史遗留授权实现，收敛重复的工具裁剪与运行时设置代码。

**Architecture:** 以 `ToolAuthorizationPolicy` 作为执行主体级授权模型，结合 `AppSettings` 全局开关、`ToolGrant` 角色上限、`ToolContext` 上下文和运行时前提，统一通过 `ToolAuthorizationResolver` 产出 `EffectiveToolAuthorizationSnapshot`，再分别投影为工具列表和临时运行时 settings。后台任务和渠道页面复用同一套 `ToolPermissionSectionView`。

**Tech Stack:** Swift 6、SwiftData、SwiftUI、Foundation、现有 `ToolRegistry` / `ToolsetResolver`、`ClaudeService`、后台任务系统、渠道系统、Swift Testing。

---

## 0. 范围约束

- 本轮只交付“整体工具权限控制”，不做逐次审批弹窗。
- 本轮不引入细粒度文件路径 ACL、命令 allowlist 或联网域名 allowlist。
- 本轮必须让后台任务完全切换到新授权方案，旧 `BackgroundTaskToolGrantPolicy` 不保留。
- 本轮必须让渠道设置页可配置整体工具权限，第一版 UI 样式与后台任务现有“工具权限”区域保持一致。
- 本轮允许主会话与部分 workflow 调用暂时继续沿用现有行为，但新增架构必须兼容未来接入。
- 本轮不考虑旧设计兼容性，不安排历史数据迁移任务，不保留双字段或双轨逻辑。
- 所有授权解析逻辑必须集中到共享 resolver / factory，禁止继续在后台任务和渠道执行器中保留独立工具裁剪分支。

## 1. 实施原则

- 先建立统一模型和纯解析层，再替换后台任务与渠道接线，并在切换时同步删除旧实现。
- 先补 focused tests 锁定授权矩阵与投影行为，再做 SwiftUI 和运行时替换，避免“改完只能靠人工点点看”。
- 不做兼容层，不做迁移辅助代码，不保留旧字段兜底读取。
- 预算与授权严格分离。`maxRounds`、调度和 QoS 不是工具授权的一部分。
- 全局开关仍是总闸，新授权不能绕过 `AppSettings`。

## 2. 当前依赖与改造落点

当前实现计划直接依赖这些现有文件和能力：

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolGrant.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskToolGrantPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteExecutionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`

已确认的现状：

- 后台任务有一套专用 `trustTier + bool flags` 授权模型和专用 UI 归一化逻辑。
- 远程渠道使用 `RemoteExecutionPolicy` 同时承载工具授权和执行预算。
- 后台任务与渠道都在各自执行器中手工裁剪 `AppSettings` 和工具集合。
- `ToolRegistry` / `ToolsetResolver` 已经承担基础工具解析能力，适合作为统一授权的底座。

## 3. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolAuthorizationPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolAuthorizationResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedToolsetProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedRuntimeSettingsFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolPermissionEditorModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ToolPermissionSectionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolAuthorizationPolicyTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolAuthorizationResolverTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AuthorizedRuntimeSettingsFactoryTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPermissionEditorModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelToolAuthorizationIntegrationTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteExecutionPolicy.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolsetResolver.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelConfiguration.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelRuntimeBootstrap.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`

### 删除文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskToolGrantPolicy.swift`

## 4. 关键架构决策

### 4.1 主体级授权与角色级授权分层

`ToolGrant` 保留，继续表达角色或上下文的静态上限。新引入的 `ToolAuthorizationPolicy` 只表达执行主体的运行时授权边界。最终结果由 resolver 做求交。

### 4.2 工具能力通过声明驱动，不通过工具 ID 分支驱动

`ToolDefinition` 必须补充授权描述，例如能力需求和风险等级。后续 resolver 不应继续散落 `switch toolID` 来决定权限要求。

### 4.3 运行时 settings 投影集中处理

后台任务和渠道都不应再直接手工改写 `AppSettings`。统一由 `AuthorizedRuntimeSettingsFactory` 根据授权快照生成临时 settings。

### 4.4 UI 首版保持熟悉感，但底层不再绑定旧模型

后台任务和渠道页继续展示“信任等级 + 4 个开关”的交互模型，但底层数据必须绑定到统一的 `ToolAuthorizationPolicy`。

### 4.5 切换新逻辑时直接删除旧方案

如果后台任务旧模型和旧归一化逻辑仍被保留，后续渠道、桌面工具和 specialist 授权会继续分叉，因此本计划要求在切换新逻辑的同一轮提交中删除旧实现。

## 5. 阶段拆解

### Phase 1: 建立统一授权模型与纯解析层

目标：先把模型、能力矩阵、工具声明和 resolver 做成可测试的纯层，不碰 UI 和运行时接线。

产出：

- `ToolAuthorizationPolicy`
- `ToolAuthorizationResolver`
- `EffectiveToolAuthorizationSnapshot`
- `ToolDefinition.authorization` 扩展

验收标准：

- 能独立对“全局关闭 / 主体拒绝 / ToolGrant 缺失 / 上下文不支持”给出稳定判定。
- 能覆盖文本编辑、Bash、网络、记忆四类首版能力。

### Phase 2: 建立共享投影层与设置编辑模型

目标：让 UI 和运行时不需要理解授权求交细节，只消费统一快照和编辑模型。

产出：

- `AuthorizedToolsetProjector`
- `AuthorizedRuntimeSettingsFactory`
- `ToolPermissionEditorModel`
- `ToolPermissionSectionView`

验收标准：

- 后台任务和渠道都能复用同一设置 section。
- 共享编辑模型能复现当前后台任务 trust tier 的启用/禁用约束。

### Phase 3: 后台任务直接替换为统一授权

目标：把后台任务直接替换为新模型，不保留旧 `BackgroundTaskToolGrantPolicy` 的兼容读取或过渡逻辑。

产出：

- `BackgroundAgentTask.authorizationPolicy`
- `BackgroundTaskManagementViewModel` 改造
- `SettingsBackgroundTasksView` 改造
- `BackgroundAgentLoopAdapter` 切换到共享 resolver / factory

验收标准：

- 后台任务旧 UI 行为保持一致。
- 后台任务执行的工具集合和运行时 settings 全部来自共享授权层。

### Phase 4: 渠道直接切换到统一授权

目标：为渠道增加整体工具权限控制，并切换远程执行逻辑。

产出：

- `ChannelAccountBinding.authorizationPolicy`
- `ChannelSettingsViewModel` 改造
- `SettingsChannelsView` 新增共享权限 section
- `RemoteExecutionPolicy` 拆出预算字段，去掉工具授权字段
- 渠道执行器切换到共享 resolver / factory

验收标准：

- 渠道页可保存整体工具权限。
- 渠道远程执行不再维护专属工具裁剪代码。

### Phase 5: 删除旧代码并补齐回归测试

目标：删除旧后台任务授权代码，确保共享授权层成为唯一实现。

产出：

- 删除 `BackgroundTaskToolGrantPolicy.swift`
- 删除后台任务旧 trust tier 归一化分支
- 删除渠道旧 `allowFileWrite / allowBash / allowNetworkTools` 裁剪代码
- 补齐 focused tests

验收标准：

- 搜索代码库时，不再存在后台任务旧授权模型引用。
- 后台任务与渠道执行路径都通过统一授权层。

## 6. 详细任务拆解

### Task 1: 建立统一授权值类型与预设矩阵

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolAuthorizationPolicy.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolAuthorizationPolicyTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `ToolAuthorizationPolicy` 默认值对应 `observeOnly`
- `observeOnly / maintain / actLimited` 的能力矩阵稳定
- 手动修改能力等级后 preset 能切到 `custom`
- 能正确表达 `fileSystem`、`shell`、`network`、`memory` 四类能力

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolAuthorizationPolicyTests
```

**Step 3: Write the minimal implementation**

- 实现 `ToolCapabilityID`
- 实现 `ToolCapabilityLevel`
- 实现 `ToolAuthorizationPreset`
- 实现 `ToolAuthorizationPolicy`
- 给出首版预设矩阵工厂

**Step 4: Run focused tests**

Expected: PASS

### Task 2: 扩展 ToolDefinition 的授权声明并实现 resolver

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolDefinition.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ToolAuthorizationResolver.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolAuthorizationResolverTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `str_replace_based_edit_tool` 需要 `fileSystem.mutate`
- `bash` 需要 `shell.execute`
- `web_search` / `web_fetch` 需要 `network.observe`
- 当 `AppSettings` 全局关闭时，即使主体策略允许也必须拒绝
- 当 `ToolGrant` 缺失时工具不可见
- 返回的 deny reason 可区分 `globallyDisabled`、`subjectPolicyDenied`、`contextUnsupported`、`roleGrantMissing`

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolAuthorizationResolverTests
```

**Step 3: Write the minimal implementation**

- 在 `ToolDefinition` 上增加授权描述
- 实现 `EffectiveToolAuthorizationSnapshot`
- 实现 `ToolAuthorizationResolver`

**Step 4: Run focused tests**

Expected: PASS

### Task 3: 建立统一工具投影与运行时 settings 工厂

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedToolsetProjector.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AuthorizedRuntimeSettingsFactory.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AuthorizedRuntimeSettingsFactoryTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- 相同授权快照可生成稳定工具列表
- `fileSystem.mutate` 会开启文本编辑工具
- `shell.execute` 会开启 Bash
- `network.observe` 会开启 Web Search / Web Fetch
- `memory.mutate` 会开启 memory
- 后台任务和渠道共用同一 settings factory，无需各自维护裁剪逻辑

**Step 2: Run test to verify it fails**

**Step 3: Write the minimal implementation**

- 实现 projector
- 实现 runtime settings factory
- 让其消费 resolver 产物

**Step 4: Run focused tests**

Expected: PASS

### Task 4: 抽共享工具权限编辑模型和设置组件

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolPermissionEditorModel.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/ToolPermissionSectionView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolPermissionEditorModelTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `observeOnly` 下文件写入、Bash、记忆写入不可启用
- `maintain` 下文件写入、Bash 不可启用，但记忆写入可启用
- `actLimited` 下四个开关都可操作
- 降级 preset 时超出上限的开关会自动关闭

**Step 2: Write the minimal implementation**

- 把当前后台任务 trust tier 文案迁到共享 editor model
- `ToolPermissionSectionView` 暴露 `Binding<ToolAuthorizationPolicy>`
- 组件保持当前后台任务表单结构和文案风格

**Step 3: Run focused tests**

Expected: PASS

### Task 5: 后台任务切换到统一授权模型

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundAgentTask.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/BackgroundTaskManagementViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsBackgroundTasksView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Background/Adapters/BackgroundAgentLoopAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BackgroundTaskManagementViewModelTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- `BackgroundAgentTask` 能读写 `authorizationPolicy`
- 后台任务 ViewModel 通过共享 editor model 管理权限
- 后台任务执行器不再直接读取旧 `toolGrantPolicy`
- 后台任务实际工具集合与运行时 settings 来自共享 resolver / factory

**Step 2: Write the implementation**

- `BackgroundAgentTask` 以 `authorizationPolicyJSON` 取代旧授权字段
- ViewModel 的 `draftToolGrantPolicy` 替换为 `draftAuthorizationPolicy`
- 设置页将 `toolsSection` 替换为 `ToolPermissionSectionView`
- `BackgroundAgentLoopAdapter` 删除旧 `effectivePolicy(...)` 和专属工具列表分支，改接共享服务
- 同步删除旧 `toolGrantPolicy` 相关字段、方法和引用

**Step 3: Run focused tests**

Expected: PASS

### Task 6: 渠道页接入整体工具权限控制并切换远程执行

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/RemoteExecutionPolicy.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/IMChannelConfiguration.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelRuntimeBootstrap.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/RemoteAgentOrchestrator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelToolAuthorizationIntegrationTests.swift`

**Step 1: Write the failing tests**

覆盖以下行为：

- 渠道绑定能持久化 `authorizationPolicy`
- 渠道设置页能加载和保存统一授权策略
- `RemoteExecutionPolicy` 只保留预算字段，不再承载工具权限
- 远程执行链路使用共享授权层生成运行时 settings

**Step 2: Write the implementation**

- `ChannelAccountBinding` 增加 `authorizationPolicyJSON`
- `ChannelSettingsViewModel` 增加 `authorizationPolicy`
- `SettingsChannelsView` 新增 `ToolPermissionSectionView`
- 渠道配置对象显式传入 `ToolAuthorizationPolicy`
- 远程执行器删除旧布尔裁剪分支，改接共享 resolver / factory
- `RemoteExecutionPolicy` 只保留预算定义，不再保留旧工具授权字段

**Step 3: Run focused tests**

Expected: PASS

### Task 7: 删除后台任务旧授权实现并做回归清理

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/BackgroundTaskToolGrantPolicy.swift`
- Modify: all remaining references

**Step 1: Remove old implementation**

- 删除旧模型文件
- 删除旧 ViewModel 方法：例如旧 trust tier 专用归一化 helpers
- 删除旧执行器分支和旧字段引用

**Step 2: Run full focused regression**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/ToolAuthorizationPolicyTests \
  -only-testing:agentGuiTests/ToolAuthorizationResolverTests \
  -only-testing:agentGuiTests/AuthorizedRuntimeSettingsFactoryTests \
  -only-testing:agentGuiTests/ToolPermissionEditorModelTests \
  -only-testing:agentGuiTests/BackgroundTaskManagementViewModelTests \
  -only-testing:agentGuiTests/ChannelToolAuthorizationIntegrationTests
```

**Step 3: Run smoke validation**

优先执行现有任务：

- `Quality Smoke`

Expected: 若仓库里存在无关基线失败，需要在结果里明确区分新增变更和存量问题。

## 7. 持久化与切换策略

### 7.1 后台任务持久化重写

- `BackgroundAgentTask` 直接改为持久化 `authorizationPolicyJSON`。
- 旧 `toolGrantPolicyJSON` 与 `BackgroundTaskToolGrantPolicy` 在新逻辑接入时直接删除。
- 不提供旧字段兼容读取，也不为旧记录保留回退逻辑。

### 7.2 渠道持久化重写

- `ChannelAccountBinding` 直接新增 `authorizationPolicyJSON`，作为渠道主体授权唯一来源。
- `RemoteExecutionPolicy` 直接收缩为预算值类型，不保留旧工具授权字段。

### 7.3 切换要求

- 同一轮实现必须完成“新字段接线 + 新逻辑生效 + 旧字段删除”。
- 不允许存在“双字段读取 / 单字段写入”或任何兼容窗口。

## 8. 测试计划

至少覆盖以下测试面：

- 纯值类型测试：预设矩阵、能力等级、custom 退化
- Resolver 测试：全局总闸、主体策略、角色上限、上下文限制
- Factory 测试：运行时 settings 投影、工具列表投影
- ViewModel 测试：后台任务与渠道都能正确加载/保存策略
- UI 交互测试：共享权限 section 的禁用/自动关闭逻辑
- 集成测试：后台任务和远程渠道都走共享授权层

如果测试时间有限，优先级如下：

1. `ToolAuthorizationResolverTests`
2. `AuthorizedRuntimeSettingsFactoryTests`
3. `BackgroundTaskManagementViewModelTests`
4. `ChannelToolAuthorizationIntegrationTests`
5. `ToolPermissionEditorModelTests`

## 9. 风险与缓解

### 9.1 ToolDefinition 授权声明不完整

风险：某些工具未声明授权需求，导致 resolver 判定失真。

缓解：先只覆盖当前后台任务和渠道实际会用到的工具，测试中强制校验核心工具声明存在。

### 9.2 共享 UI 抽取后行为偏离后台任务现状

风险：用户可感知到设置行为改变。

缓解：把当前后台任务文案、禁用规则和自动关闭逻辑原样搬到 `ToolPermissionEditorModel`，先追求一致性，再做后续优化。

### 9.3 渠道接线时把预算和授权重新耦合

风险：`RemoteExecutionPolicy` 被继续塞回工具权限字段。

缓解：代码评审时明确 `RemoteExecutionPolicy` 只承载预算；授权一律从 `ChannelAccountBinding.authorizationPolicy` 读取。

## 10. 提交建议

建议按以下提交序列推进：

1. `feat: add unified tool authorization policy and resolver`
2. `feat: add shared tool permission editor and settings section`
3. `refactor: replace background task auth with unified authorization`
4. `feat: add channel-level tool authorization control`
5. `refactor: remove legacy tool authorization codepaths`

## 11. 完成定义

满足以下条件才算本计划完成：

1. 渠道设置页已经具备整体工具权限控制。
2. 后台任务已切换到统一授权模型。
3. 后台任务旧授权代码已删除。
4. 后台任务和渠道都通过共享 resolver / projector / runtime settings factory 执行。
5. 共享 `ToolPermissionSectionView` 已复用于后台任务和渠道。
6. focused tests 通过，且 smoke 结果已记录新增变更与存量问题边界。