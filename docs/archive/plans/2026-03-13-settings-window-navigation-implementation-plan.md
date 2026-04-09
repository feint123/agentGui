# Settings Window Navigation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move app settings out of the main window tab bar into a dedicated macOS settings window, and reorganize existing settings into type-based navigation pages without changing the underlying `AppSettings` persistence model.

**Architecture:** Introduce a dedicated settings scene at the app level and a new settings shell view that owns sidebar-style navigation plus per-category detail pages. Keep all existing settings bound to the same `AppSettings` instance and existing save flows, but split `ContentView.swift` so the main workspace no longer owns settings UI composition.

**Tech Stack:** Swift 6, SwiftUI for macOS, SwiftData, existing `AppSettings`, `PersistenceCoordinator`, `ClaudeService`, `SkillService`, XCTest / Swift Testing.

---

## 1. 实施原则

- 先完成窗口与导航骨架，再迁移具体设置分组，避免一边拆窗口一边混改业务逻辑。
- 不修改 `AppSettings` 字段定义，本次只重组视图和入口。
- 主窗口与设置窗口职责必须清晰分离，避免继续把设置实现留在 `ContentView.swift`。
- UI 测试入口要和窗口改造同步更新，不能等功能完成后再补。
- 迁移过程中尽量复用现有保存辅助逻辑，避免因重写 binding 导致设置回归。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsConnectionView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsIntelligenceView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsNavigationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsUITests.swift`

## 3. 任务拆解

### Task 1: 建立设置导航模型与默认路由规则

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsNavigationTests.swift`

**Step 1: 写失败测试，固定导航契约**

覆盖以下行为：

- 导航项顺序固定为 `connection -> tools -> intelligence -> memory -> general`
- 默认导航项是 `connection`
- 每个导航项都有稳定的标题和 SF Symbol

测试示例：

```swift
import Testing
@testable import agentGui

struct SettingsNavigationTests {
    @Test func settingsNavigationUsesExpectedDefaultOrder() {
        #expect(SettingsNavigationItem.allCases == [.connection, .tools, .intelligence, .memory, .general])
        #expect(SettingsNavigationItem.defaultItem == .connection)
    }
}
```

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SettingsNavigationTests
```

Expected: FAIL，因为导航模型尚不存在。

**Step 3: 写最小实现**

在 `SettingsNavigationItem.swift` 中新增：

```swift
enum SettingsNavigationItem: String, CaseIterable, Identifiable {
    case connection
    case tools
    case intelligence
    case memory
    case general

    static let defaultItem: SettingsNavigationItem = .connection

    var id: String { rawValue }
    var title: String { ... }
    var symbolName: String { ... }
}
```

要求：

- 标题面向用户，不暴露内部实现命名
- 枚举顺序直接作为导航顺序来源
- 后续 UI 测试可复用 `rawValue` 生成 accessibility id

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsNavigationItem.swift agentGuiTests/SettingsNavigationTests.swift
git commit -m "feat: add settings navigation model"
```

### Task 2: 抽出设置共享状态与持久化辅助层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsNavigationTests.swift`

**Step 1: 写失败测试，固定默认加载与最近访问导航项行为**

覆盖以下行为：

- `SettingsStore` 默认选中 `connection`
- 加载时能拿到 `AppSettings.getOrCreate(...)`
- 可更新 `selectedItem` 并持有最近访问值

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SettingsNavigationTests
```

Expected: FAIL，因为共享状态层尚不存在。

**Step 3: 写最小实现**

新增 `SettingsStore`，负责：

- 缓存 `AppSettings` 引用
- 暴露 `selectedItem`
- 复用保存辅助方法，例如 `persistSettingsMutation(...)`
- 提供各详情页复用的 `Binding` 构造能力

同时把 `ContentView.swift` 中只属于设置页的保存辅助逻辑迁出，避免设置窗口仍依赖主窗口文件中的私有方法。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsStore.swift agentGui/ContentView.swift agentGuiTests/SettingsNavigationTests.swift
git commit -m "refactor: extract shared settings store"
```

### Task 3: 建立设置窗口骨架与独立场景入口

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

**Step 1: 写失败 UI 测试，固定独立窗口入口**

覆盖以下行为：

- 应用可以打开设置窗口
- 窗口内默认显示“连接”导航项
- 右侧详情页出现 `settings.connection.apiKeyField`

建议不要再依赖 `initialTab = settings`，而是新增专门的测试打开路径。

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SettingsWindowUITests
```

Expected: FAIL，因为设置窗口和入口尚不存在。

**Step 3: 写最小实现**

在 `agentGuiApp.swift` 中新增设置场景，并在 `ContentView.swift` 中补一个应用内入口。设置窗口骨架至少包含：

- 左侧导航列表
- 右侧占位详情页
- 默认选中 `connection`

要求：

- 主窗口移除 `AppTab.settings`
- 使用单独设置窗口，而不是 sheet
- 入口在测试环境下可稳定触发

**Step 4: 再跑 focused UI tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/agentGuiApp.swift agentGui/ContentView.swift agentGui/Views/Settings/SettingsWindowView.swift agentGuiUITests/SettingsWindowUITests.swift
git commit -m "feat: add dedicated settings window shell"
```

### Task 4: 迁移连接与通用页面，确保基础配置先可用

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsConnectionView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

**Step 1: 写失败测试，固定页面映射**

覆盖以下行为：

- “连接”页展示 API Key、Base URL、模型、代理、连接状态
- “通用”页展示主题、版本、AI 服务信息
- 原有保存动作在新页面仍可触发

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SettingsWindowUITests
```

Expected: FAIL，因为详情页尚未迁移完成。

**Step 3: 写最小实现**

把原 `SettingsView` 中以下内容迁移出去：

- API Key section
- proxy section
- model section
- appearance section
- about section

要求：

- 不改变现有保存文案和 `ClaudeService.applyConnectionSettings(settings)` 调用时机
- `connection` 与 `general` 的 accessibility id 按页面范围重新命名
- 从 `ContentView.swift` 删除已经迁移的设置视图片段

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsConnectionView.swift agentGui/Views/Settings/SettingsGeneralView.swift agentGui/ContentView.swift agentGuiUITests/SettingsWindowUITests.swift
git commit -m "feat: migrate connection and general settings pages"
```

### Task 5: 迁移工具页面，重点覆盖 LSP 与工作目录配置

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsToolsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/LSPSettingsTests.swift`

**Step 1: 写失败测试，固定工具页面展示契约**

覆盖以下行为：

- “工具”页出现 Text Editor、Bash、Web Search、Web Fetch、LSP 相关项
- 开启 Bash 后工作目录输入框出现
- 开启 LSP 后路由策略和 JSON 编辑器出现

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SettingsWindowUITests -only-testing:agentGuiTests/LSPSettingsTests
```

Expected: FAIL，因为工具页尚未迁移。

**Step 3: 写最小实现**

迁移原 `toolsSection` 到独立页面，并保持：

- Web Search / Ollama API Key 的条件显示逻辑
- LSP profile summary 与 JSON 验证提示
- 保存失败文案不变

不要在这个任务里修改 LSP 业务逻辑，只做 UI 迁移与绑定复用。

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsToolsView.swift agentGui/ContentView.swift agentGuiUITests/SettingsWindowUITests.swift agentGuiTests/LSPSettingsTests.swift
git commit -m "feat: migrate tool settings page"
```

### Task 6: 迁移智能与记忆页面，完成长表单拆分

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsIntelligenceView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsMemoryView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/MemoryRuntimeSettingsTests.swift`

**Step 1: 写失败测试，固定智能与记忆页行为**

覆盖以下行为：

- “智能”页包含 Extended Thinking 与 Reflection
- “记忆”页包含统一记忆运行时、治理、后台调度、TTL Sweep、长期记忆编辑器
- 打开记忆治理面板入口仍存在

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SettingsWindowUITests -only-testing:agentGuiTests/MemoryRuntimeSettingsTests
```

Expected: FAIL，因为相关页面尚未迁移。

**Step 3: 写最小实现**

迁移以下内容：

- `Extended Thinking` section
- `反思循环` section
- `memorySection` 中的全部统一记忆运行时配置
- 长期记忆编辑器与保存动作

要求：

- 继续复用 `ConfigDirectoryManager.shared.readMemory()` / `writeMemory(...)`
- 不改变 MemoryManagementPanel 的打开方式
- 保持 slider、stepper 的取值范围不变

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Settings/SettingsIntelligenceView.swift agentGui/Views/Settings/SettingsMemoryView.swift agentGui/ContentView.swift agentGuiUITests/SettingsWindowUITests.swift agentGuiTests/MemoryRuntimeSettingsTests.swift
git commit -m "feat: migrate intelligence and memory settings pages"
```

### Task 7: 清理主窗口结构并完成测试启动参数迁移

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/TestLaunchOptions.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsUITests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/SettingsWindowUITests.swift`

**Step 1: 写失败测试，固定新测试入口**

覆盖以下行为：

- 测试模式可以显式打开设置窗口
- `initialTab` 不再接受 `settings`
- 旧测试迁移到新窗口入口后仍能验证 API Key 字段存在

**Step 2: 运行测试确认失败**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiUITests/SettingsUITests -only-testing:agentGuiUITests/SettingsWindowUITests
```

Expected: FAIL，因为启动参数和旧测试仍依赖旧 Tab。

**Step 3: 写最小实现**

完成以下清理：

- 删除 `AppTab.settings`
- 删除主窗口中的设置 Tab item
- 为 UI 测试增加新的设置窗口打开标志或辅助命令
- 把旧 `SettingsUITests` 改造成面向独立窗口的兼容测试，或合并到 `SettingsWindowUITests`

**Step 4: 再跑 focused tests**

Run 同 Step 2。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ContentView.swift agentGui/Utilities/TestLaunchOptions.swift agentGuiUITests/SettingsUITests.swift agentGuiUITests/SettingsWindowUITests.swift
git commit -m "refactor: remove settings tab and update test entry"
```

### Task 8: 执行全量回归并补文档说明

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-13-settings-window-navigation-requirements.md`

**Step 1: 运行全量相关测试**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/SettingsNavigationTests -only-testing:agentGuiTests/LSPSettingsTests -only-testing:agentGuiTests/MemoryRuntimeSettingsTests -only-testing:agentGuiUITests/SettingsWindowUITests
```

Expected: PASS。

如果仓库已有快速质量脚本，再运行：

```bash
./scripts/run_quality_smoke.sh
```

Expected: PASS 或至少确认与本次改动相关部分无新增失败。

**Step 2: 更新文档**

在 `README.md` 或相关说明中补充：

- 设置入口位置
- 设置窗口的分类结构
- 测试环境如何打开设置窗口

**Step 3: Commit**

```bash
git add README.md docs/plans/2026-03-13-settings-window-navigation-requirements.md
git commit -m "docs: document standalone settings window"
```

## 4. 风险控制点

- 如果 `Settings` 场景在测试环境下不易稳定唤起，优先补一个显式应用内按钮供 UI 测试触发，再逐步收敛到系统标准入口。
- 如果 `ContentView.swift` 拆分过大导致冲突，应先提取新文件，再最小化收缩旧文件，避免一次性大删大改。
- 如果最近访问导航项持久化影响范围过大，可以先在内存态完成，等窗口结构稳定后再持久化。

## 5. 完成定义

- 主窗口不再包含 Settings Tab。
- 设置以独立窗口提供，并有稳定入口。
- 设置窗口包含 5 个分类导航项。
- 现有设置项完成迁移且保存行为不变。
- 相关单元测试与 UI 测试通过。

Plan complete and saved to `docs/plans/2026-03-13-settings-window-navigation-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?