# Chat InputArea Voice Input Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 agentGui 的聊天 InputArea 中落地首版语音输入按钮，支持点击开始/点击结束、实时转写、结果并回现有输入框、权限与失败提示，并保持现有发送链路与辅助输入行为稳定。

**Architecture:** 方案分三层。第一层是会话内语音状态控制器 `VoiceInputController`，负责状态机、文本快照和错误提示；第二层是 `SpeechCaptureSession`，负责 SpeechAnalyzer、SpeechTranscriber、AVAudioEngine 和麦克风输入；第三层是 ChatView/InputArea 集成层，只负责展示按钮、状态文案和把实时结果并回现有 `inputText`。实现坚持 session-local、TDD、最小 UI 侵入，不引入单独音频持久化或旧 API 双栈。

**Tech Stack:** Swift 6, SwiftUI, Observation, AVFAudio, Speech, AppKit, Swift Testing, existing ChatView/InputArea architecture.

---

## 0. 执行约束

- 我正在使用 writing-plans skill 来创建实现计划。
- 严格按 @test-driven-development 执行：先写失败测试，再写最小实现，再跑通过。
- 首期只做 macOS 26+ 的 `SpeechAnalyzer + SpeechTranscriber` 主链，不接 `SFSpeechRecognizer` 兜底。
- 语音结果必须回写到现有 `ChatView.inputText`，继续复用 [agentGui/Views/ChatView+Actions.swift](agentGui/Views/ChatView+Actions.swift#L67) 的 `sendMessage()` 链路。
- `ChatView` 是多扩展文件结构，共享的 `@State` 不能随意标成 `private`；遵守仓库里对跨文件 `@State` 可见性的经验约束。
- 工程当前使用生成式 Info.plist，隐私键需要直接写入 [agentGui.xcodeproj/project.pbxproj](agentGui.xcodeproj/project.pbxproj#L412) 和 [agentGui.xcodeproj/project.pbxproj](agentGui.xcodeproj/project.pbxproj#L467) 对应的 app target build settings。
- 优先新增纯逻辑单测，不在首轮引入依赖真实麦克风的 UI 自动化。
- 如果新 Swift 文件在 target 可见性上出现异常编译问题，优先检查项目同步根组行为；必要时把极小实现临时放进现有文件，但测试文件仍保持独立。

## 1. 目标文件清单

### 新增文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/VoiceInputPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/VoiceInputController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SpeechCaptureSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/VoiceInputButton.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VoiceInputControllerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SpeechCaptureSessionTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VoiceInputButtonPresentationTests.swift`

### 修改文件

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift:32-71`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift:50-220`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift:634-684`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift:67-157`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj:412-481`

### 参考文件

- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-26-chat-input-voice-input-design.md`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatComposerExecutionPresentationTests.swift:1-58`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChatInputCommandParserTests.swift:1-95`

## 2. 验证命令

### Focused voice-input tests

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-voice-input-plan \
  -only-testing:agentGuiTests/VoiceInputControllerTests \
  -only-testing:agentGuiTests/SpeechCaptureSessionTests \
  -only-testing:agentGuiTests/VoiceInputButtonPresentationTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 语音输入新增测试全部通过；如果 scheme 仍然连带构建 UI test target，只记录签名噪音，不把它误判为语音模块实现错误。

### Compile fallback when test environment is noisy

```bash
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-voice-input-plan-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: app target和新增测试 target 至少编译通过，用于区分实现错误与本地测试环境噪音。

## 3. 目标数据结构

### 语音状态模型

```swift
enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case recording
    case finalizing
    case failed(String)
}
```

### 控制器公开面

```swift
@MainActor
@Observable
final class VoiceInputController {
    var phase: VoiceInputPhase = .idle
    var liveTranscript: String = ""
    var displayedText: String = ""
    var startedAt: Date?

    func startRecording(currentText: String) async
    func stopRecording() async
    func cancelRecording() async
    func handleManualTextMutation(_ text: String) async
}
```

### 底层采集会话协议

```swift
protocol SpeechCaptureSessionProtocol: Sendable {
    func start(locale: Locale) async throws -> AsyncThrowingStream<SpeechCaptureSession.Event, Error>
    func stop() async throws
    func cancel() async
}
```

## 4. 任务拆解

### Task 1: 先锁定语音状态机与文本合并策略

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/VoiceInputPhase.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/VoiceInputController.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VoiceInputControllerTests.swift`

**Step 1: Write the failing test**

先为 `VoiceInputController` 写失败测试，覆盖四个核心行为：

```swift
import Foundation
import Testing
@testable import agentGui

@MainActor
struct VoiceInputControllerTests {
    @Test func partialTranscriptAppendsToEmptyComposer() async throws {
        let harness = VoiceInputControllerHarness()
        let controller = harness.makeController()

        await controller.beginSessionForTesting(currentText: "")
        await controller.consumeEvent(.partial("hello world"))

        #expect(controller.displayedText == "hello world")
        #expect(controller.liveTranscript == "hello world")
        #expect(controller.phase == .recording)
    }

    @Test func partialTranscriptUsesNewlineSeparatorForNonEmptyComposer() async throws {
        let harness = VoiceInputControllerHarness()
        let controller = harness.makeController()

        await controller.beginSessionForTesting(currentText: "已有文本")
        await controller.consumeEvent(.partial("继续口述"))

        #expect(controller.displayedText == "已有文本\n继续口述")
    }

    @Test func finalTranscriptCommitsIntoDisplayedText() async throws {
        let harness = VoiceInputControllerHarness()
        let controller = harness.makeController()

        await controller.beginSessionForTesting(currentText: "")
        await controller.consumeEvent(.partial("第一段"))
        await controller.consumeEvent(.final("第一段 完成"))

        #expect(controller.displayedText == "第一段 完成")
        #expect(controller.liveTranscript == "第一段 完成")
        #expect(controller.phase == .idle)
    }

    @Test func editingBaseTextDuringRecordingStopsSessionAndKeepsVisibleText() async throws {
        let harness = VoiceInputControllerHarness()
        let controller = harness.makeController()

        await controller.beginSessionForTesting(currentText: "原始")
        await controller.consumeEvent(.partial("语音"))
        await controller.handleManualTextMutation("手动改写原始")

        #expect(controller.phase == .idle)
        #expect(controller.displayedText == "手动改写原始\n语音")
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-voice-task1 -only-testing:agentGuiTests/VoiceInputControllerTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `VoiceInputPhase`、`VoiceInputController` 和测试辅助 API 还不存在。

**Step 3: Write minimal implementation**

先写纯逻辑最小实现，不接 Speech API：

```swift
enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case preparing
    case recording
    case finalizing
    case failed(String)
}

@MainActor
@Observable
final class VoiceInputController {
    var phase: VoiceInputPhase = .idle
    var liveTranscript: String = ""
    var displayedText: String = ""

    private var baseInputText: String = ""

    func beginSessionForTesting(currentText: String) {
        baseInputText = currentText
        displayedText = currentText
        phase = .recording
    }

    func consumeEvent(_ event: VoiceInputTestEvent) {
        switch event {
        case let .partial(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
        case let .final(text):
            liveTranscript = text
            displayedText = Self.merge(base: baseInputText, transcript: text)
            phase = .idle
        }
    }
}
```

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Models/VoiceInputPhase.swift agentGui/Services/VoiceInputController.swift agentGuiTests/VoiceInputControllerTests.swift
git commit -m "feat: add voice input controller state machine"
```

### Task 2: 为 SpeechAnalyzer 采集层建立可替换接口和失败测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SpeechCaptureSession.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SpeechCaptureSessionTests.swift`

**Step 1: Write the failing test**

先锁定底层采集层的行为接口，而不是直接测真实麦克风：

```swift
import Foundation
import Testing
@testable import agentGui

struct SpeechCaptureSessionTests {
    @Test func unavailableLocaleThrowsHelpfulError() async throws {
        let session = SpeechCaptureSession(
            transcriberFactory: .alwaysUnsupported,
            microphoneAuthorizer: .authorized,
            audioEngineFactory: .noop
        )

        await #expect(throws: SpeechCaptureSession.Error.unsupportedLocale) {
            _ = try await session.start(locale: Locale(identifier: "zz-ZZ"))
        }
    }

    @Test func startPublishesPartialAndFinalEventsFromStream() async throws {
        let session = SpeechCaptureSession.fixtureStreaming([
            .partial("alpha"),
            .final("alpha beta")
        ])

        let stream = try await session.start(locale: Locale(identifier: "zh-CN"))
        var received: [SpeechCaptureSession.Event.Kind] = []

        for try await event in stream {
            received.append(event.kind)
        }

        #expect(received.count == 2)
    }

    @Test func stopFinalizesWithoutCancellingActiveStream() async throws {
        let harness = SpeechCaptureSessionHarness()
        let session = harness.makeSession()

        _ = try await session.start(locale: Locale(identifier: "zh-CN"))
        try await session.stop()

        #expect(await harness.didFinalize)
        #expect(await harness.didCancel == false)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-voice-task2 -only-testing:agentGuiTests/SpeechCaptureSessionTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为底层 session 和依赖注入接口还不存在。

**Step 3: Write minimal implementation**

先写协议化骨架和 fake-friendly 实现，第二轮再接 Apple 真 API：

```swift
actor SpeechCaptureSession: SpeechCaptureSessionProtocol {
    struct Event: Sendable {
        enum Kind: Sendable, Equatable {
            case partial(String)
            case final(String)
            case unavailable(String)
        }

        let kind: Kind
    }

    enum Error: Swift.Error, Equatable {
        case unsupportedLocale
        case microphonePermissionDenied
        case initializationFailed(String)
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<Event, Swift.Error> { ... }
    func stop() async throws { ... }
    func cancel() async { ... }
}
```

这一任务的目标不是把 `AVAudioEngine` 和 `SpeechAnalyzer` 一次写满，而是把：

- 权限检查入口
- locale 可用性检查入口
- partial / final 事件流接口
- `stop()` 与 `cancel()` 语义

先固定下来。

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/SpeechCaptureSession.swift agentGuiTests/SpeechCaptureSessionTests.swift
git commit -m "feat: add speech capture session abstraction"
```

### Task 3: 把控制器接到底层采集会话，并补权限/失败路径

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/VoiceInputController.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SpeechCaptureSession.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VoiceInputControllerTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/SpeechCaptureSessionTests.swift`

**Step 1: Write the failing test**

给控制器补三类集成级逻辑测试：

```swift
@MainActor
@Test func startRecordingTransitionsThroughPreparingIntoRecording() async throws {
    let session = FakeSpeechCaptureSession(events: [.partial("开始")])
    let controller = VoiceInputController(captureSession: session)

    await controller.startRecording(currentText: "")

    #expect(controller.phase == .recording)
    #expect(controller.displayedText == "开始")
}

@MainActor
@Test func permissionFailurePublishesFailedPhase() async throws {
    let session = FakeSpeechCaptureSession(startError: .microphonePermissionDenied)
    let controller = VoiceInputController(captureSession: session)

    await controller.startRecording(currentText: "")

    #expect(controller.phase == .failed("需要麦克风权限"))
}

@MainActor
@Test func stopRecordingFinalizesAndReturnsToIdle() async throws {
    let session = FakeSpeechCaptureSession(events: [.partial("甲"), .final("甲乙")])
    let controller = VoiceInputController(captureSession: session)

    await controller.startRecording(currentText: "")
    await controller.stopRecording()

    #expect(controller.phase == .idle)
    #expect(controller.displayedText == "甲乙")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-voice-task3 -only-testing:agentGuiTests/VoiceInputControllerTests -only-testing:agentGuiTests/SpeechCaptureSessionTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为控制器尚未真正消费采集事件流，也没有把错误映射为用户可见状态。

**Step 3: Write minimal implementation**

把 `VoiceInputController` 接成真正的状态协调器：

```swift
func startRecording(currentText: String) async {
    guard phase == .idle else { return }
    baseInputText = currentText
    displayedText = currentText
    phase = .preparing

    do {
        let stream = try await captureSession.start(locale: .current)
        phase = .recording
        listeningTask = Task {
            for try await event in stream {
                await self.consume(event)
            }
        }
    } catch SpeechCaptureSession.Error.microphonePermissionDenied {
        phase = .failed("需要麦克风权限")
    } catch {
        phase = .failed("语音输入启动失败")
    }
}
```

并补：

- `stopRecording()` 调 `captureSession.stop()`
- `cancelRecording()` 调 `captureSession.cancel()`
- partial / final 事件更新 `displayedText`

**Step 4: Run test to verify it passes**

同上命令。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Services/VoiceInputController.swift agentGui/Services/SpeechCaptureSession.swift agentGuiTests/VoiceInputControllerTests.swift agentGuiTests/SpeechCaptureSessionTests.swift
git commit -m "feat: wire voice controller to speech capture session"
```

### Task 4: 集成 ChatView/InputArea，并补按钮展示测试

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/VoiceInputButton.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/VoiceInputButtonPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView.swift:32-71`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift:50-220`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+InputArea.swift:634-684`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+Actions.swift:67-157`

**Step 1: Write the failing test**

先测按钮 presentation，不直接做 SwiftUI 截图测试：

```swift
import Testing
@testable import agentGui

struct VoiceInputButtonPresentationTests {
    @Test func idlePhaseUsesMicrophoneSymbol() {
        let presentation = VoiceInputButtonPresentation.make(phase: .idle, isEnabled: true)

        #expect(presentation.symbolName == "mic.fill")
        #expect(presentation.isEmphasized == false)
    }

    @Test func recordingPhaseUsesStopSymbolAndEmphasis() {
        let presentation = VoiceInputButtonPresentation.make(phase: .recording, isEnabled: true)

        #expect(presentation.symbolName == "stop.circle.fill")
        #expect(presentation.isEmphasized == true)
    }

    @Test func failedPhaseStaysRetryable() {
        let presentation = VoiceInputButtonPresentation.make(phase: .failed("x"), isEnabled: true)

        #expect(presentation.symbolName == "mic.fill")
        #expect(presentation.isEnabled)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' -parallel-testing-enabled NO -derivedDataPath /tmp/agentGui-voice-task4 -only-testing:agentGuiTests/VoiceInputButtonPresentationTests CODE_SIGNING_ALLOWED=NO
```

Expected: FAIL，因为 `VoiceInputButton` 及其 presentation helper 还不存在。

**Step 3: Write minimal implementation**

先新建按钮组件，再接入 `ChatView`：

```swift
struct VoiceInputButton: View {
    let phase: VoiceInputPhase
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let presentation = VoiceInputButtonPresentation.make(phase: phase, isEnabled: isEnabled)
        Button(action: action) {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(presentation.foregroundStyle)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .accessibilityIdentifier("chat.voiceInputButton")
    }
}
```

然后在 [agentGui/Views/ChatView.swift](agentGui/Views/ChatView.swift#L32) 附近新增状态：

- `@State var voiceInputController = VoiceInputController()`

在 [agentGui/Views/ChatView+InputArea.swift](agentGui/Views/ChatView+InputArea.swift#L634) 的发送按钮区域改成动作簇：

- `VoiceInputButton`
- 现有 `stopStreaming` 按钮
- 现有发送按钮

同时在 [agentGui/Views/ChatView+InputArea.swift](agentGui/Views/ChatView+InputArea.swift#L50) 的状态行加“正在听写”/错误提示文案。

在 [agentGui/Views/ChatView+Actions.swift](agentGui/Views/ChatView+Actions.swift#L67) 周围补：

- `toggleVoiceInput()`
- `syncComposerTextFromVoiceControllerIfNeeded()`

要求：控制器的 `displayedText` 变更时同步到 `inputText` 并继续调用 `updateComposerAssistState(_:)`。

**Step 4: Run test to verify it passes**

先跑 presentation test，再跑完整 focused voice-input tests。

Expected: PASS。

**Step 5: Commit**

```bash
git add agentGui/Views/VoiceInputButton.swift agentGui/Views/ChatView.swift agentGui/Views/ChatView+InputArea.swift agentGui/Views/ChatView+Actions.swift agentGuiTests/VoiceInputButtonPresentationTests.swift
git commit -m "feat: integrate voice input controls into chat input area"
```

### Task 5: 补工程隐私键与最终回归

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui.xcodeproj/project.pbxproj:412-481`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-26-chat-input-voice-input-design.md`（仅当实现命名偏离设计时）
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-26-chat-input-voice-input-implementation-plan.md`（仅在执行时记录必要纠偏）

**Step 1: Write the failing test**

这一步不新增单测，直接把隐私键配置与最终验收视为完成定义的一部分。

**Step 2: Run test to verify it fails**

先运行 focused tests；若因为 Info.plist 缺键导致运行时问题尚未暴露，继续完成配置后再做 build/test 验证。

**Step 3: Write minimal implementation**

在 [agentGui.xcodeproj/project.pbxproj](agentGui.xcodeproj/project.pbxproj#L412) 和 [agentGui.xcodeproj/project.pbxproj](agentGui.xcodeproj/project.pbxproj#L467) 的 app target build settings 增加：

```text
INFOPLIST_KEY_NSMicrophoneUsageDescription = "agentGui 使用麦克风将你的语音实时转写为聊天输入内容，不会在未触发时持续录音。";
```

首期不要加入 `NSSpeechRecognitionUsageDescription`，除非实现中真的引入了旧 `SFSpeechRecognizer` 路径。

**Step 4: Run test to verify it passes**

Run:

```bash
xcodebuild test \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-voice-input-plan \
  -only-testing:agentGuiTests/VoiceInputControllerTests \
  -only-testing:agentGuiTests/SpeechCaptureSessionTests \
  -only-testing:agentGuiTests/VoiceInputButtonPresentationTests \
  CODE_SIGNING_ALLOWED=NO
```

如果本地 `xcodebuild test` 仍被环境噪音干扰，再跑：

```bash
xcodebuild build-for-testing \
  -project agentGui.xcodeproj \
  -scheme agentGui \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/agentGui-voice-input-plan-build \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 新增语音输入模块编译通过，focused tests 通过，且无与本次实现直接相关的新增错误。

**Step 5: Commit**

```bash
git add agentGui.xcodeproj/project.pbxproj docs/plans/2026-03-26-chat-input-voice-input-design.md docs/plans/2026-03-26-chat-input-voice-input-implementation-plan.md
git commit -m "docs: finalize voice input implementation plan"
```

## 5. 重点风险提示

1. `SpeechAnalyzer` / `SpeechTranscriber` 的真 API 接入可能需要比假会话更多的异步准备步骤，Task 2 和 Task 3 必须先把接口和错误边界锁死，再接真实依赖。
2. `ChatView` 的 `inputText` 仍参与 slash / mention / todo 解析，Task 4 接入后必须确保 `updateComposerAssistState(_:)` 继续被调用，不要直接绕过现有链路。
3. 录音期间手动编辑冲突是首期最可能反复改动的部分，必须把“前置文本被改动即停止录音”的保守策略写成测试，不要边做边漂。
4. 生成式 Info.plist 配置如果只改了一套 build settings，会导致 Debug/Release 表现不一致；Task 5 要同时改 app target 的两套配置块。

## 6. 完成定义

满足以下条件才算完成：

1. InputArea 出现可点击的语音输入按钮。
2. 点击后能进入录音态，再次点击能结束。
3. partial transcript 会实时更新到当前输入框。
4. final transcript 会保留在输入框中，并继续复用现有发送链路。
5. 权限拒绝、locale 不支持、初始化失败时有明确错误态。
6. 工程已补 `NSMicrophoneUsageDescription`。
7. focused voice-input tests 通过，或至少 `build-for-testing` 证明新增模块编译健康。

## 7. 执行交接

Plan complete and saved to `docs/plans/2026-03-26-chat-input-voice-input-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?