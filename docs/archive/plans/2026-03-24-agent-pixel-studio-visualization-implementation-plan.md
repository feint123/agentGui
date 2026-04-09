# Agent 像素工作室可视化 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 agentGui 增加一个独立的 Agent 工作室窗口，用 SpriteKit 以像素角色形式可视化多个会话的执行状态，并且不影响现有对话与运行时链路。

**Architecture:** 先把执行运行时里工作室真正需要的元数据补齐为稳定的纯值投影，再引入一个 `@MainActor` 的 `AgentStudioProjectionBuilder` 把 Session、执行投影和当前工具调用摘要汇总成 `Sendable` 场景状态。SwiftUI 只负责窗口和 `SpriteView` 挂载，SpriteKit `SKScene` 只消费纯值投影并执行最小 diff 更新；所有渲染生命周期控制都放在独立窗口内完成，避免对 `WorkbenchShellView` 造成额外耦合和常驻 GPU 消耗。

**Tech Stack:** Swift 6、SwiftUI for macOS、SpriteKit、GameplayKit、SwiftData、Observation、现有 `ClaudeService` / `ExecutionProjectionStore` / `Session` 模型、Swift Testing、XCTest UI tests。

**Depends On:** [docs/plans/2026-03-24-agent-pixel-studio-visualization-design.md](../plans/2026-03-24-agent-pixel-studio-visualization-design.md)

---

## 0. Read This First

- 使用 @test-driven-development 执行所有生产代码改动。每一轮先补失败测试，再写最小实现，再跑定向验证。
- 使用 @swiftui-expert-skill 处理窗口 Scene、`AgentStudioWindowView`、`AgentStudioView` 以及任何新的 SwiftUI 挂载代码。保持状态所有权单向、`body` 纯净。
- 不要把 SpriteKit 场景直接连到 `Session`、`ToolCall` 或 `ClaudeService` 这些可变对象上。场景层只能接收 `Sendable` 纯值投影。
- 不要把这次实现做成 Workbench 内嵌 panel。当前方案已经确认以独立 Window 为主，Workbench 仅提供打开入口。
- `SessionExecutionProjection` 目前只有队列/运行态和 provider 信息，没有 `currentPhase`。动画映射依赖这条元数据，因此它必须作为第一批前置改动完成。
- 仓库里没有现成的 `ToolCallSnapshot` 链路。计划中会新增一条“当前工具名摘要”暴露链路，但只做工作室所需的最小只读摘要，不要顺带重做整套工具审计模型。
- 像素资源先使用占位资源或最小可编译资源集验证工程链路，避免在第一轮就把风险堆到大量美术导入上。
- 如果 macOS UI tests 受本地签名或窗口焦点问题影响，至少执行一次构建验证：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

## 1. Scope Guardrails

- 不改动现有 `ChatView` 消息流、composer 交互、会话列表和 Change Review 逻辑。
- 不把工作室做成可写控制台；它只展示运行态，不直接驱动运行时状态变更。
- 不为这次功能引入新的第三方包。只使用 Apple 平台框架。
- 不一次性实现所有皮肤、全部粒子和完整交互。MVP 先打通单窗口、状态投影、基础动画和最小 HUD。
- 不顺手重构整个执行投影系统；仅补齐 `currentPhase`、当前工具名和工作室真正需要的只读接口。
- 不把资源管理做成通用编辑器。只约定当前工作室所需的 atlas、tile、particle 命名和占位资源。

## 2. Relevant Existing Files

### 应用入口与窗口注册

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/WorkbenchSceneServices.swift`

### 会话与执行状态

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Session.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`

### 现有 Workbench 和聊天入口

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchShellView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Workbench/WorkbenchConversationPane.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift`

### 优先扩展的测试

- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/UITestBase.swift`

## 3. Target File Plan

### New Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentStudioProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentStudioProjectionBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/AgentStudioWindowScene.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioWindowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioScene.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentCharacterNode.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/SpeechBubbleNode.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionBuilderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionMappingTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentStudioWindowUITests.swift`

### Modified Files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

### Asset / Resource Work

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Assets.xcassets/`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/`

如果在实现中发现 `SpeechBubbleNode` 或 `AgentCharacterNode` 太小，不必强行拆出独立文件；但默认先按上面的文件边界规划，避免 `AgentStudioScene.swift` 变成新的超大文件。

## 4. Implementation Order

先补执行态元数据，再引入工作室值模型和 builder，然后搭建窗口与 SpriteKit 场景，最后补动画/工具态细节、资源和功耗控制。

---

### Task 1: 补齐工作室所需的执行投影元数据

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ExecutionProjectionStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Execution/ConversationExecutionOrchestrator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ExecutionProjectionStoreTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ConversationExecutionOrchestratorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift`

**Step 1: Write the failing tests**

先锁定 `SessionExecutionProjection` 的新契约：

- 默认空投影的 `currentPhase == nil`
- 运行中投影能携带 `currentPhase`
- 队列流转、取消、完成后 `currentPhase` 随投影同步更新
- 现有依赖 `SessionExecutionProjection` 的测试在新增字段后仍能明确指定默认值，避免隐式回归

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct ExecutionProjectionStoreTests {
    @Test func projectionStoreReturnsEmptyProjectionForUnknownSession() {
        let store = ExecutionProjectionStore()

        let projection = store.projection(for: "session-1")

        #expect(projection.sessionID == "session-1")
        #expect(projection.currentPhase == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/ExecutionProjectionStoreTests \
  -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests \
  -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests
```

Expected: FAIL because `SessionExecutionProjection` does not yet expose `currentPhase` and all initializers have not been updated.

**Step 3: Write minimal implementation**

最小实现：

- 给 `SessionExecutionProjection` 添加 `currentPhase: AgentLoopPhase?`
- 更新 `empty(sessionID:)` 和所有构造点，显式传入 `nil` 或当前值
- 在 `ConversationExecutionOrchestrator` 中把运行中的 phase 一并写回 projection
- 如果同一个会话只是排队未运行，保持 `currentPhase == nil`，不要伪造 phase

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ExecutionProjection.swift agentGui/Services/Execution/ExecutionProjectionStore.swift agentGui/Services/Execution/ConversationExecutionOrchestrator.swift agentGuiTests/ExecutionProjectionStoreTests.swift agentGuiTests/ConversationExecutionOrchestratorTests.swift agentGuiTests/ChatComposerExecutionPresentationTests.swift
git commit -m "feat: expose execution phase for studio projection"
```

### Task 2: 建立 Agent 工作室值模型与映射规则

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentStudioProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ConversationExecutionProviderID.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionMappingTests.swift`

**Step 1: Write the failing tests**

锁定纯值映射规则：

- provider 到默认皮肤的映射
- `AgentLoopPhase` 到 `CharacterAnimationState` 的映射
- 没有活跃会话时角色不应生成
- 超过 8 个 session 时只取前 8 个工位

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

struct AgentStudioProjectionMappingTests {
    @Test func providerMapsToExpectedSkin() {
        #expect(ConversationExecutionProviderID.openCodeCLI.defaultCharacterSkin == .robot)
    }

    @Test func awaitingToolResultsDefaultsToTyping() {
        #expect(CharacterAnimationState.make(phase: .awaitingToolResults, toolName: nil) == .typing)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/AgentStudioProjectionMappingTests
```

Expected: FAIL because the new model and mapping helpers do not exist.

**Step 3: Write minimal implementation**

在 `AgentStudioProjection.swift` 中定义：

- `AgentStudioProjection`
- `AgentCharacterState`
- `CharacterAnimationState`
- `CharacterSkin`
- `WorkstationSlot`
- `SpeechBubblePresentation`
- `StudioTheme`

同时：

- 在 `ConversationExecutionProviderID` 增加 `defaultCharacterSkin`
- 为 phase/toolName 提供纯函数映射入口，例如 `CharacterAnimationState.make(phase:toolName:)`
- 保持这些类型全部 `Equatable`、`Sendable`

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AgentStudioProjection.swift agentGui/Models/ConversationExecutionProviderID.swift agentGuiTests/AgentStudioProjectionMappingTests.swift
git commit -m "feat: add agent studio projection models"
```

### Task 3: 构建 ProjectionBuilder，把 Session / 执行态 / 当前工具名汇总成场景投影

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentStudioProjectionBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService/ClaudeService.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionBuilderTests.swift`

**Step 1: Write the failing tests**

锁定 builder 的输入输出：

- 按 session 更新时间倒序或当前查询顺序取前 8 个会话
- 执行中的 session 映射到对应动画状态
- 有活跃工具调用时生成 `currentToolName` 和 `speechBubble`
- 没有执行投影时回落到 idle

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentStudioProjectionBuilderTests {
    @Test func rebuildMapsRunningSessionToThinkingCharacter() {
        let builder = AgentStudioProjectionBuilder()
        let session = Session()
        session.title = "Primary"
        session.defaultExecutionProviderID = ConversationExecutionProviderID.builtInAgent.rawValue

        let projection = builder.makeProjection(
            sessions: [session],
            execProjections: [
                session.sessionId: SessionExecutionProjection(
                    sessionID: session.sessionId,
                    runningJobID: UUID(),
                    queuedJobIDs: [],
                    queuedCount: 0,
                    isRunning: true,
                    canEditComposer: true,
                    canSubmitNewJob: true,
                    activeProviderID: .builtInAgent,
                    currentPhase: .executing
                )
            ],
            currentToolNames: [:]
        )

        #expect(projection.characters.count == 1)
        #expect(projection.characters[0].animationState == .thinking)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/AgentStudioProjectionBuilderTests
```

Expected: FAIL because the builder and current tool snapshot entry points do not exist.

**Step 3: Write minimal implementation**

最小实现：

- 新建 `AgentStudioProjectionBuilder`，至少提供纯函数 `makeProjection(...)` 和一个可观察的 `projection`
- 在 builder 内把 session/provider/phase/toolName 映射为 `AgentCharacterState`
- 在 `ClaudeService` 增加一个只读入口，暴露“每个 session 当前活跃工具名”的最小摘要来源
- 如果 `ToolCall.title` 比 `kind` 更可靠，就优先使用标题；若没有标题，回退到 `kind.rawValue` 或已有定义 ID

不要在这一任务里引入 SpriteKit、窗口或通知监听。

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentStudioProjectionBuilder.swift agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService/ClaudeService.swift agentGuiTests/AgentStudioProjectionBuilderTests.swift
git commit -m "feat: build agent studio projection from runtime state"
```

### Task 4: 搭建独立窗口入口和 SwiftUI 挂载层

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Utilities/AgentStudioWindowScene.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentStudioWindowUITests.swift`

**Step 1: Write the failing tests**

锁定工作室窗口能被打开：

- 有稳定的 scene id
- 菜单命令能触发窗口打开
- 新窗口根视图存在可访问性标识，例如 `window.agentStudio`

UI 草图：

```swift
import XCTest

final class AgentStudioWindowUITests: UITestBase {
    @MainActor
    func testAgentStudioWindowCanOpen() throws {
        launchApp(arguments: ["-com.agentgui.test.mode"])

        app.menuBars.menuBarItems["窗口"].click()
        app.menuBars.menuItems["显示 Agent 工作室"].click()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "window.agentStudio").firstMatch.waitForExistence(timeout: 2))
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/AgentStudioWindowUITests
```

Expected: FAIL because the scene, menu command, and root view do not exist.

**Step 3: Write minimal implementation**

最小实现：

- 新增 `AgentStudioWindowScene.id`
- 在 `agentGuiApp` 注册 `Window("Agent 工作室", id: ...)`
- 添加新的 `StudioMenuCommands` 或在现有 command group 中追加按钮
- 新建 `AgentStudioWindowView` 和 `AgentStudioView`，先用占位 `Text` 或空 `SpriteView` 验证窗口链路
- 给根容器设置 `accessibilityIdentifier("window.agentStudio")`

先不要接入完整 SpriteKit 场景 diff，只保证窗口可打开、可编译、环境注入正确。

**Step 4: Re-run the focused tests**

Run the same command from Step 2. Then run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: UI test PASS，build PASS。

**Step 5: Commit**

```bash
git add agentGui/Utilities/AgentStudioWindowScene.swift agentGui/Views/Studio/AgentStudioView.swift agentGui/Views/Studio/AgentStudioWindowView.swift agentGui/agentGuiApp.swift agentGuiUITests/AgentStudioWindowUITests.swift
git commit -m "feat: register agent studio window"
```

### Task 5: 实现 SpriteKit 场景骨架与角色节点最小 diff 更新

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioScene.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentCharacterNode.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/SpeechBubbleNode.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionMappingTests.swift`

**Step 1: Write the failing tests**

因为 SpriteKit UI 很难直接做快照单测，这一轮锁定可测试的纯逻辑接口：

- `AgentStudioScene.applyProjection(_:)` 之前先通过内部 helper 计算新增、更新、移除的角色 id
- `SpeechBubblePresentation` 到气泡文本/样式映射可单测
- 角色状态切换对同态输入幂等

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

struct AgentStudioProjectionMappingTests {
    @Test func sceneDiffDetectsRemovedCharacterIDs() {
        let previous = ["a", "b"]
        let incoming = ["b", "c"]

        let diff = AgentStudioSceneDiff.make(existingIDs: previous, incomingIDs: incoming)

        #expect(diff.removedIDs == ["a"])
        #expect(diff.insertedIDs == ["c"])
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/AgentStudioProjectionMappingTests
```

Expected: FAIL because the scene diff helpers and SpriteKit wrapper types do not yet exist.

**Step 3: Write minimal implementation**

最小实现：

- 新建 `AgentStudioScene`，配置透明背景、像素过滤、基础层级节点
- 新建 `AgentCharacterNode`，先支持 idle / thinking / typing / error 的占位纹理切换
- 新建 `SpeechBubbleNode`，先支持文本显隐，不急着做复杂气泡样式
- 在 `AgentStudioView` 中用 `SpriteView(scene:)` 挂载场景
- 在 `AgentStudioWindowView` 中把 builder.projection 的变化推给 scene

**Step 4: Re-run the focused tests**

Run the same command from Step 2, then执行构建验证：

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/Studio/AgentStudioScene.swift agentGui/Views/Studio/AgentCharacterNode.swift agentGui/Views/Studio/SpeechBubbleNode.swift agentGui/Views/Studio/AgentStudioView.swift agentGui/Views/Studio/AgentStudioWindowView.swift agentGuiTests/AgentStudioProjectionMappingTests.swift
git commit -m "feat: add spritekit scene shell for agent studio"
```

### Task 6: 把实时数据绑定到窗口，并加入窗口生命周期节能控制

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentStudioProjectionBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioWindowView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioScene.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/agentGuiApp.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiUITests/AgentStudioWindowUITests.swift`

**Step 1: Write the failing tests**

锁定绑定和生命周期行为：

- 窗口出现时开始接收 execution projection 更新
- 应用失焦或窗口不可见时暂停 scene
- 重新激活后恢复更新
- 空场景时 scene 可暂停，避免无意义渲染

UI 或单元测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct AgentStudioProjectionBuilderTests {
    @Test func builderPublishesEmptyProjectionWhenNoSessions() {
        let builder = AgentStudioProjectionBuilder()

        let projection = builder.makeProjection(sessions: [], execProjections: [:], currentToolNames: [:])

        #expect(projection.characters.isEmpty)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/AgentStudioProjectionBuilderTests \
  -only-testing:agentGuiUITests/AgentStudioWindowUITests
```

Expected: FAIL because live binding and pause/resume hooks are not wired.

**Step 3: Write minimal implementation**

最小实现：

- 让 `AgentStudioProjectionBuilder` 提供绑定入口，例如接受 sessions、`ExecutionProjectionStore` 和工具摘要来源
- 在 `AgentStudioWindowView` 中监听 app active/inactive 通知
- 把暂停/恢复渲染封装到 `AgentStudioScene`，例如 `setRenderingPaused(_:)`
- 当 `projection.characters.isEmpty` 时允许暂停 scene，但不要阻断下一次投影恢复

**Step 4: Re-run the focused tests**

Run the same command from Step 2.

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentStudioProjectionBuilder.swift agentGui/Views/Studio/AgentStudioWindowView.swift agentGui/Views/Studio/AgentStudioScene.swift agentGui/agentGuiApp.swift agentGuiTests/AgentStudioProjectionBuilderTests.swift agentGuiUITests/AgentStudioWindowUITests.swift
git commit -m "feat: bind agent studio window to live execution state"
```

### Task 7: 加入读工具动画、HUD 和最小资源集

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentStudioProjection.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentStudioProjectionBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentStudioScene.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Studio/AgentCharacterNode.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Assets.xcassets/`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Resources/`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentStudioProjectionMappingTests.swift`

**Step 1: Write the failing tests**

锁定第一批视觉语义：

- `read_file`、`list_dir`、`grep_search` 这类读取工具映射到 `.reading`
- `.finalizing` 映射到 `.celebrating`
- 长时间无会话或空工位显示 sleeping / empty workstation 策略时保持稳定
- HUD 标签和工位分配不会因 session 更新顺序抖动

测试草图：

```swift
import Foundation
import Testing
@testable import agentGui

struct AgentStudioProjectionMappingTests {
    @Test func readToolMapsToReadingAnimation() {
        #expect(CharacterAnimationState.make(phase: .awaitingToolResults, toolName: "read_file") == .reading)
    }
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/AgentStudioProjectionMappingTests
```

Expected: FAIL because reading-state mapping, HUD details, and resource assumptions are not complete.

**Step 3: Write minimal implementation**

最小实现：

- 在 phase/toolName 映射里加入 read 类工具白名单
- 在 `AgentStudioScene` 补工位标签、基础进度条或占位 HUD
- 导入最小可运行资源集：至少一个皮肤的 idle/thinking/typing/reading/error/celebrating atlas，以及必要的桌面或占位 tile
- 缺少最终美术时使用明确占位资源命名，不要把临时 png 随机塞进资源目录

**Step 4: Re-run the focused tests and build**

Run the same command from Step 2. Then run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/AgentStudioProjection.swift agentGui/ViewModels/AgentStudioProjectionBuilder.swift agentGui/Views/Studio/AgentStudioScene.swift agentGui/Views/Studio/AgentCharacterNode.swift agentGui/Assets.xcassets agentGui/Resources agentGuiTests/AgentStudioProjectionMappingTests.swift
git commit -m "feat: add agent studio visual states and starter assets"
```

## 5. Verification Matrix

### Focused Unit Tests

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiTests/ExecutionProjectionStoreTests \
  -only-testing:agentGuiTests/ConversationExecutionOrchestratorTests \
  -only-testing:agentGuiTests/ChatComposerExecutionPresentationTests \
  -only-testing:agentGuiTests/AgentStudioProjectionMappingTests \
  -only-testing:agentGuiTests/AgentStudioProjectionBuilderTests
```

### Focused UI Test

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO test \
  -only-testing:agentGuiUITests/AgentStudioWindowUITests
```

### Build Smoke

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO build CODE_SIGNING_ALLOWED=NO
```

### Optional Repo Smoke

使用现有任务：

```bash
./scripts/run_quality_smoke.sh
```

如果只想在任务末尾做一次最小仓库回归，也可以执行 VS Code 任务 `Quality Smoke`。

## 6. Open Questions To Resolve During Execution

1. `currentPhase` 最稳定的写入点是否就在 `ConversationExecutionOrchestrator`，还是需要更靠近 `AgentLoopPhaseOutcomeApplier` 的投影同步层。
2. “当前工具名”究竟是取 `ToolCall.title`、`kind`、`toolDefinitionID` 还是三者优先级回退。实现前要先在样本数据里确认哪个最稳定。
3. 像素资源第一轮是直接提交 CC0 占位资源，还是先用程序化占位纹理打通渲染链路。优先选择风险更低的一种。
4. 是否需要为工作室窗口增加显式设置项控制默认打开状态。MVP 可不做，但如果在实现中发现用户很容易误触打开，需要补最小偏好位。

## 7. Suggested Execution Notes

- 先完成 Task 1 到 Task 3，再开始任何 SpriteKit 代码。否则渲染层会建立在不稳定的运行时契约上。
- Task 4 完成后先用占位场景跑通窗口，再进入 Task 5 和 Task 7 的资源工作，避免 UI/资源/投影三条线同时出问题。
- 每做完一个 Task 都执行该任务自己的 focused tests，不要等到最后再统一排错。

Plan complete and saved to `docs/plans/2026-03-24-agent-pixel-studio-visualization-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?