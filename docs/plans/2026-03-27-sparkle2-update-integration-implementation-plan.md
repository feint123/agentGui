# Sparkle 2.0 Update Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 接入 Sparkle 2 标准更新链路，完成应用内“检查更新”、更新偏好设置、Beta 渠道切换、基础发布脚本与上线验收路径。

**Architecture:** 采用薄封装方案，把 Sparkle 2 的 `SPUStandardUpdaterController` 隔离在独立 Update 模块里，通过 coordinator + delegate + preferences bridge 暴露给 SwiftUI App 生命周期、Commands 平台和设置页。运行时不把更新逻辑耦合进 `ClaudeService` 或 ACP runtime；用户偏好中只有 agentGui 自己需要持久化的渠道选择进入 `AppSettings`，Sparkle 自带的自动检查和自动更新偏好仍由 Sparkle 背后的 `UserDefaults` 管理。

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Sparkle 2, Swift Testing, xcodebuild, shell scripts, generated Info.plist keys in Xcode project settings.

---

## 1. 实施原则

- 全程按 @test-driven-development 执行：先写失败测试，再补最小实现，再验证通过。
- 由于当前工程使用 `GENERATE_INFOPLIST_FILE = YES`，不要创建独立 Info.plist；Sparkle 配置要写到 `agentGui.xcodeproj/project.pbxproj` 的 `INFOPLIST_KEY_*` 和用户自定义 build settings。
- 当前 scheme 会顺带构建 UI test target；每个任务优先跑精确 `-only-testing:` 的 suite，整体编译健康用 `build-for-testing CODE_SIGNING_ALLOWED=NO` 验证。
- Sparkle 类型不要直接扩散到菜单和设置层；通过自定义协议或薄适配器隔离，保证单元测试不依赖真实 Sparkle UI。
- Phase 1 不启用 signed feed；先把稳定主链路跑通，再在后续任务中为 signed feed 和 release hardening 预留接口。
- 每个任务完成后都提交一次，避免把 Xcode project、运行时接线、设置页和脚本改动混在一个提交里。
- 全部任务完成后，使用 @requesting-code-review 进行最终检查，重点看命令接线、Xcode package 变更、generated Info.plist 配置、设置页状态同步和发布脚本鲁棒性。

## 2. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateDelegate.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdatePreferencesBridge.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateChannel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsUpdatesView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SparkleUpdateCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRouterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SparkleUpdatePreferencesBridgeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsUpdatePreferencesTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/scripts/release/generate_appcast.sh`
- `/Volumes/T7/文稿/Projects/agentGui/docs/release/sparkle-release-runbook.md`

### 主要修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRequirement.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandContext.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRegistry.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRouter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Modules/AppMenuCommands.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## 3. Task 1: 引入 Sparkle 依赖并建立可测试的 Update 核心封装

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateCoordinator.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateDelegate.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdateChannel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SparkleUpdateCoordinatorTests.swift`

**Step 1: Write the failing test**

创建 `SparkleUpdateCoordinatorTests.swift`，覆盖以下行为：

- `checkForUpdates()` 会调用底层 updater driver 一次。
- `canCheckForUpdates` 状态能从 driver 初始值同步到 coordinator。
- Beta 渠道开启时，delegate 返回 `Set(["beta"])`；关闭时返回空集合。

示例：

```swift
@MainActor
@Test
func manualCheckDelegatesToDriver() async {
    let driver = StubSparkleDriver(canCheckForUpdates: true)
    let coordinator = SparkleUpdateCoordinator(driver: driver)

    await coordinator.checkForUpdates()

    #expect(driver.checkForUpdatesCallCount == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/SparkleUpdateCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing `SparkleUpdateCoordinator`, missing `SparkleUpdateDelegate`, or missing Sparkle bridge types.

**Step 3: Write minimal implementation**

- 用 SwiftPM 将 `https://github.com/sparkle-project/Sparkle` 加入 app target。
- 在 `SparkleUpdateCoordinator.swift` 中定义一个最小可测的 driver protocol，例如：

```swift
@MainActor
protocol SparkleUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    func resetUpdateCycleAfterShortDelay()
}
```

- 生产实现中再用 `SPUStandardUpdaterController` 和 `SPUUpdater` 做适配，避免测试直接依赖 Sparkle UI。
- `SparkleUpdateDelegate` 实现渠道控制，只做 `allowedChannels(for:)` 和错误记录最小骨架，不提前做 feed URL 动态切换。
- `SparkleUpdateChannel` 先只包含 `.stable` 与 `.beta` 两个 case。

**Step 4: Run test to verify it passes**

Run the same test command.

Expected: PASS for `SparkleUpdateCoordinatorTests`.

Then run a compile smoke:

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -derivedDataPath /tmp/agentGui-sparkle-core-build CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add agentGui/Services/Update/SparkleUpdateCoordinator.swift agentGui/Services/Update/SparkleUpdateDelegate.swift agentGui/Services/Update/SparkleUpdateChannel.swift agentGui.xcodeproj/project.pbxproj agentGui.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved agentGuiTests/SparkleUpdateCoordinatorTests.swift
git commit -m "feat: add sparkle update core"
```

## 4. Task 2: 将更新能力接入 App 生命周期与 Commands 平台

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandID.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRequirement.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandContext.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Core/AppCommandRouter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/AppCommands/Modules/AppMenuCommands.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AppCommandRouterTests.swift`

**Step 1: Write the failing test**

创建 `AppCommandRouterTests.swift`，覆盖：

- 新命令 `checkForUpdates` 已注册，标题为“检查更新...”。
- 当 update coordinator 可用且 `canCheckForUpdates == true` 时，router 能执行该命令。
- 当 update coordinator 不可用或 `canCheckForUpdates == false` 时，命令被禁用并返回明确原因。

示例：

```swift
@MainActor
@Test
func checkForUpdatesCommandInvokesCoordinator() async {
    let coordinator = StubUpdateCommandHandler(canCheckForUpdates: true)
    let router = AppCommandRouter()
    var context = AppCommandContext.preview()
    context.updateCommandHandler = coordinator

    let result = await router.perform(.checkForUpdates, in: context)

    #expect(result == .performed)
    #expect(coordinator.checkCallCount == 1)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/AppCommandRouterTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing enum case, missing context hook, or router not handling command.

**Step 3: Write minimal implementation**

- 在 `AppCommandID` 新增 `.checkForUpdates`。
- 在 `AppCommandRequirement` 新增 `.updateCheckAvailable`，根据 context 中的 update handler 状态判断可用性。
- 在 `AppCommandContext` 新增一个轻量 update command interface，例如：

```swift
@MainActor
protocol UpdateCommandHandling {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}
```

- 在 `agentGuiApp` 持有 `@State private var updateCoordinator`，并在 scene 环境或 focused context 组装时注入。
- 在 `AppCommandRegistry` 注册菜单标题、关键词和快捷键；快捷键建议先不设置，保留系统菜单默认体验。
- 在 `AppCommandRouter` 路由到 `updateCoordinator.checkForUpdates()`。
- `AppMenuCommands` 继续通过 registry 渲染，无需手写单独按钮逻辑，只要确保新的 descriptor 进入 app 菜单分组。

**Step 4: Run test to verify it passes**

Run the same test command.

Expected: PASS for `AppCommandRouterTests`.

Then run a command-platform smoke build:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/CommandPaletteViewModelTests CODE_SIGNING_ALLOWED=NO
```

Expected: Existing command palette tests remain green or, if absent in local scheme, no new compile regressions from command registry edits.

**Step 5: Commit**

```bash
git add agentGui/agentGuiApp.swift agentGui/AppCommands/Core/AppCommandID.swift agentGui/AppCommands/Core/AppCommandRequirement.swift agentGui/AppCommands/Core/AppCommandContext.swift agentGui/AppCommands/Core/AppCommandRegistry.swift agentGui/AppCommands/Core/AppCommandRouter.swift agentGui/AppCommands/Modules/AppMenuCommands.swift agentGuiTests/AppCommandRouterTests.swift
git commit -m "feat: wire sparkle updates into app commands"
```

## 5. Task 3: 建立更新偏好桥接与设置页入口

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Update/SparkleUpdatePreferencesBridge.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsUpdatesView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SparkleUpdatePreferencesBridgeTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SettingsUpdatePreferencesTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AppSettings.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsNavigationItem.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsGeneralView.swift`

**Step 1: Write the failing tests**

创建两个测试文件：

1. `SparkleUpdatePreferencesBridgeTests.swift`
   - automatic checks 开关会映射到底层 update driver 属性。
   - automatic install 开关会映射到底层 Sparkle 偏好。
   - 渠道切换会触发 `resetUpdateCycleAfterShortDelay()`。
2. `SettingsUpdatePreferencesTests.swift`
   - `AppSettings` 持久化 `sparkleUpdateChannelRaw` 或 `sparkleAllowsBetaChannel`。
   - `SettingsStore` 能把该字段与 update bridge 组合起来。
   - 设置页不把 `automaticallyChecksForUpdates` 这类 Sparkle 自管字段再次写进 `AppSettings`。

示例：

```swift
@MainActor
@Test
func changingUpdateChannelResetsUpdateCycle() {
    let driver = StubSparkleDriver(canCheckForUpdates: true)
    let bridge = SparkleUpdatePreferencesBridge(driver: driver)

    bridge.updateChannel = .beta

    #expect(driver.resetUpdateCycleCallCount == 1)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/SparkleUpdatePreferencesBridgeTests -only-testing:agentGuiTests/SettingsUpdatePreferencesTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL with missing bridge, missing settings field, or settings store not exposing update preferences.

**Step 3: Write minimal implementation**

- 在 `AppSettings` 增加仅属于 agentGui 自己的更新设置字段：

```swift
var sparkleUpdateChannelRaw: String = SparkleUpdateChannel.stable.rawValue
```

或若你坚持最简，也可用：

```swift
var sparkleAllowsBetaChannel: Bool = false
```

但推荐用枚举 raw value，后续扩展更稳。

- `SparkleUpdatePreferencesBridge` 封装：
  - `automaticallyChecksForUpdates`
  - `automaticallyDownloadsUpdates` 或 `automaticallyInstallsUpdates`（按 Sparkle 可用属性选一个，不要一次做太多）
  - `updateChannel`
  - `applyChannelChange()` 时调用 `resetUpdateCycleAfterShortDelay()`
- 新增 `SettingsUpdatesView`，放置：
  - 自动检查更新开关
  - 自动安装更新开关或“下载后提醒安装”说明
  - Beta 更新渠道开关或 Picker
  - “立即检查更新”按钮
- 在 `SettingsNavigationItem` 增加 `.updates`，在 `SettingsWindowView` 中接入新页面。
- 如果不想引入新的导航项，则把更新设置挂到 `SettingsGeneralView`，但本计划推荐独立 `.updates`，避免把“关于”与“更新偏好”混在一起。
- `SettingsStore` 新增 update bridge 注入点，默认使用 `SparkleUpdateCoordinator` 暴露的 bridge。

**Step 4: Run tests to verify they pass**

Run the same test command.

Expected: PASS for both update preferences suites.

Then run a settings compile smoke:

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -derivedDataPath /tmp/agentGui-sparkle-settings-build CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add agentGui/Services/Update/SparkleUpdatePreferencesBridge.swift agentGui/Views/Settings/SettingsUpdatesView.swift agentGui/Models/AppSettings.swift agentGui/Views/Settings/SettingsNavigationItem.swift agentGui/Views/Settings/SettingsWindowView.swift agentGui/Views/Settings/SettingsStore.swift agentGui/Views/Settings/SettingsGeneralView.swift agentGuiTests/SparkleUpdatePreferencesBridgeTests.swift agentGuiTests/SettingsUpdatePreferencesTests.swift
git commit -m "feat: add sparkle update settings"
```

## 6. Task 4: 配置 generated Info.plist 与运行时启动参数

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Test: no new Swift test file; use build-setting smoke and app bootstrap smoke

**Step 1: Write the failing smoke check**

先记录一个会失败的校验命令，确认当前工程尚未包含 Sparkle 关键 Info.plist 键：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -showBuildSettings | rg 'INFOPLIST_KEY_SUFeedURL|INFOPLIST_KEY_SUPublicEDKey|SPARKLE_FEED_URL|SPARKLE_PUBLIC_ED_KEY'
```

Expected: no matches or incomplete output.

**Step 2: Run smoke check to verify it fails**

Run the command above.

Expected: 没有 Sparkle build settings，或者只看到旧的通用设置。

**Step 3: Write minimal implementation**

在 `project.pbxproj` 中完成以下配置：

- 添加 Sparkle 依赖到 app target。
- 为 Debug/Release 增加用户自定义 build settings：

```text
SPARKLE_FEED_URL = https://example.com/appcast.xml
SPARKLE_PUBLIC_ED_KEY = <replace-me>
```

- 使用 generated Info.plist key 注入：

```text
INFOPLIST_KEY_SUFeedURL = $(SPARKLE_FEED_URL)
INFOPLIST_KEY_SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)
INFOPLIST_KEY_SUEnableAutomaticChecks = YES
INFOPLIST_KEY_SUAutomaticallyUpdate = NO
```

- 先不要在这一步启用 `SURequireSignedFeed`。
- 在 `agentGuiApp` 中确保 app 启动时构造 update coordinator，且仅在主 app target 生命周期里启动 updater，不在 test mode 下拉起真实 Sparkle。

**Step 4: Run smoke checks to verify it passes**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -showBuildSettings | rg 'INFOPLIST_KEY_SUFeedURL|INFOPLIST_KEY_SUPublicEDKey|SPARKLE_FEED_URL|SPARKLE_PUBLIC_ED_KEY'
```

Expected: four settings are visible with resolved values.

Then run:

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -derivedDataPath /tmp/agentGui-sparkle-config-build CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add agentGui.xcodeproj/project.pbxproj agentGui/agentGuiApp.swift
git commit -m "build: configure generated plist keys for sparkle"
```

## 7. Task 5: 增加发布脚本与运维 Runbook

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/scripts/release/generate_appcast.sh`
- Create: `/Volumes/T7/文稿/Projects/agentGui/docs/release/sparkle-release-runbook.md`

**Step 1: Write the failing shell smoke**

先写一个最小失败场景，约束脚本在缺少必要环境变量或 Sparkle 工具不存在时退出非零：

```bash
SPARKLE_BIN=/tmp/does-not-exist ./scripts/release/generate_appcast.sh
```

Expected: exit code non-zero with clear message such as `generate_appcast not found`.

**Step 2: Run smoke to verify it fails**

Run the command above.

Expected: script missing or exits unsuccessfully.

**Step 3: Write minimal implementation**

- `generate_appcast.sh` 要做的事情：
  - 严格模式：`set -euo pipefail`
  - 检查 `SPARKLE_BIN`、更新归档目录、输出目录
  - 调用 `generate_appcast`
  - 打印生成的 appcast 路径与后续上传提示
  - 不在脚本里硬编码私钥导出逻辑
- `sparkle-release-runbook.md` 记录：
  - 首次生成 EdDSA key 的步骤
  - Archive 导出与 notarization 前置条件
  - zip 与 dmg 打包方式
  - appcast 生成与上传
  - 测试旧版本升级
  - 回滚处理

**Step 4: Run smoke to verify it passes**

Run:

```bash
bash -n ./scripts/release/generate_appcast.sh
SPARKLE_BIN=/tmp/does-not-exist ./scripts/release/generate_appcast.sh
```

Expected:

- `bash -n` passes
- second command exits non-zero with intentional, human-readable failure message

**Step 5: Commit**

```bash
git add scripts/release/generate_appcast.sh docs/release/sparkle-release-runbook.md
git commit -m "docs: add sparkle release runbook and script"
```

## 8. Task 6: 完成端到端验收与上线前收口

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-27-sparkle2-update-integration-design.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-27-sparkle2-update-integration-implementation-plan.md`
- Test: focused xcodebuild suites and manual QA checklist

**Step 1: Write the failing verification checklist**

在本计划文档末尾补一段勾选清单，先列出尚未验证的事项：

- 菜单“检查更新...”显示并可点击
- 设置页 Beta 渠道切换生效
- 无更新时提示正常
- 从旧版本发现新版本
- 更新失败时不会破坏当前安装

**Step 2: Run focused verification before declaring success**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:agentGuiTests/SparkleUpdateCoordinatorTests -only-testing:agentGuiTests/AppCommandRouterTests -only-testing:agentGuiTests/SparkleUpdatePreferencesBridgeTests -only-testing:agentGuiTests/SettingsUpdatePreferencesTests CODE_SIGNING_ALLOWED=NO
```

Expected: PASS for all new focused suites.

Then run:

```bash
xcodebuild build-for-testing -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -derivedDataPath /tmp/agentGui-sparkle-final-build CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

**Step 3: Perform manual QA**

- 启动 app，打开应用菜单，验证“检查更新...”存在且可触发。
- 打开设置页“更新”，切换 Beta 渠道，重新打开设置确认已持久化。
- 用一个旧 build 和本地 appcast 做一次真实升级演练。
- 在网络断开或 appcast URL 不可达时观察错误提示。

**Step 4: Update docs with actual decisions**

- 把最终采用的更新包格式写回设计文档。
- 把 Phase 1 是否启用自动更新的决定写回设计文档。
- 若决定延后 signed feed，在设计文档里明确标记为 Phase 3 gate。

**Step 5: Commit**

```bash
git add docs/plans/2026-03-27-sparkle2-update-integration-design.md docs/plans/2026-03-27-sparkle2-update-integration-implementation-plan.md
git commit -m "docs: finalize sparkle rollout verification"
```

## 9. 实施顺序与停靠点

推荐严格按以下顺序推进：

1. Task 1 先完成 Sparkle 依赖和可测试封装。
2. Task 2 打通 app 启动与命令入口。
3. Task 3 再做设置桥接和 UI。
4. Task 4 最后补 generated Info.plist 与启动 gating。
5. Task 5 完成发布脚本和 runbook。
6. Task 6 做验收、文档回填和上线前收口。

不要提前做的事：

- 不要在 Task 1 就启用 `SURequireSignedFeed`。
- 不要在未完成 Task 2 前把 Sparkle 直接塞进 `SettingsGeneralView`。
- 不要把真实 feed URL 或真实公钥写死在代码文件中；它们应该在 Xcode build settings 层可替换。

## 10. 最终质量门槛

实现完成后，至少满足以下条件才算可合并：

- 新增 focused test suites 全绿。
- `build-for-testing CODE_SIGNING_ALLOWED=NO` 通过。
- 应用菜单可触发“检查更新...”。
- 设置页中的更新渠道状态可持久化。
- 生成的 build settings 中包含 `SUFeedURL` 和 `SUPublicEDKey`。
- 发布脚本具备明确失败输出，不会静默成功。
- runbook 足够让不了解 Sparkle 的工程师按步骤完成一次发布。

## 11. 执行提示

- 如果 Sparkle 的 Swift API 名称与计划略有偏差，以当前 Sparkle 2 文档和 Xcode 自动补全为准，但保持本计划的分层边界不变。
- 如果 `SPUUpdater` 的自动下载 or 自动安装属性在当前版本 API 中命名不同，优先保留“自动检查 + 手动安装”最小能力，不要为了对齐文案引入过度封装。
- 如果 `AppCommandContext` 注入 update handler 影响范围过大，可以退一步改成在 `AppCommandRouter` 初始化时注入 update handler provider；但不要回退到全局单例。

Plan complete and saved to `docs/plans/2026-03-27-sparkle2-update-integration-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
