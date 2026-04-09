# Chat InputArea 语音输入设计文档

> **文档状态:** 研究草稿 · 2026-03-26  
> **作者:** 基于 Apple 官方 Speech / AVFAudio 文档与 agentGui 现有实现的调研分析  
> **目标平台:** macOS 26+  
> **交互前提:** InputArea 采用“点击开始 / 点击结束”的语音输入按钮  
> **关联代码:** `agentGui/Views/ChatView.swift`, `agentGui/Views/ChatView+InputArea.swift`, `agentGui/Views/ChatView+Actions.swift`, `agentGui/agentGuiApp.swift`, `agentGui/agentGui.entitlements`, `agentGui.xcodeproj/project.pbxproj`

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [Apple 官方文档调研结论](#2-apple-官方文档调研结论)
3. [现有代码基线](#3-现有代码基线)
4. [需求定义与非目标](#4-需求定义与非目标)
5. [交互方案选型](#5-交互方案选型)
6. [推荐架构](#6-推荐架构)
7. [状态模型与数据流](#7-状态模型与数据流)
8. [UI 集成设计](#8-ui-集成设计)
9. [权限、隐私与失败处理](#9-权限隐私与失败处理)
10. [实施拆分](#10-实施拆分)
11. [测试策略](#11-测试策略)
12. [风险与权衡](#12-风险与权衡)
13. [附录：参考资料](#13-附录参考资料)

---

## 1. 背景与目标

agentGui 当前的聊天输入区已经具备以下能力：

- 多 provider 执行态展示
- slash / mention / todo 辅助输入
- 文件拖拽与上下文拼接
- 发送、停止、禁用态控制

但 `InputArea` 仍然只有键盘输入路径，没有语音转文字入口。对于桌面场景，这会带来两个明显缺口：

1. 用户无法像系统听写或现代聊天应用一样快速口述长句。
2. 当前输入区的“高摩擦”集中在长提示词编辑，而不是消息发送本身。

本设计的目标是在 **不破坏现有输入区结构与发送语义** 的前提下，为 `InputArea` 增加一个可切换的语音输入按钮，实现以下能力：

- 点击按钮开始录音与实时转写
- 点击按钮结束录音并将最终文本合并到当前输入框
- 在录音过程中提供明确的视觉反馈，满足 Apple 对录音提醒的 UX 建议
- 权限被拒绝、设备不支持、模型资源缺失时给出可理解的降级提示
- 保持与现有 `ChatView` / `sendMessage()` / 辅助输入状态兼容

本次设计明确不追求“系统级 Dictation 替代品”，而是实现一个 **聊天输入区内的轻量、可靠、可测试** 的语音转写能力。

---

## 2. Apple 官方文档调研结论

### 2.1 首选 API：SpeechAnalyzer + SpeechTranscriber

Apple 在 Speech 文档中已经将 `SpeechAnalyzer` 与 `SpeechTranscriber` 作为新的语音转文字主路径，官方示例《Bringing advanced speech-to-text capabilities to your app》也是围绕这套 API 展开。对本项目最关键的结论有四点：

1. `SpeechAnalyzer` 负责管理分析会话，输入与输出都采用 Swift Concurrency 友好的 `AsyncSequence` 模型。
2. `SpeechTranscriber` 负责会话级语音转文字，支持实时结果流。
3. Apple 明确提供 `AssetInventory`、`bestAvailableAudioFormat(compatibleWith:)` 与 `prepareToAnalyze(in:)`，说明官方推荐应用先准备模型资源、选择兼容音频格式，再开始实时输入。
4. `SpeechAnalyzer` / `SpeechTranscriber` 的可用平台是 macOS 26+，与当前项目的部署目标一致。

这意味着 agentGui 不需要为了兼容性优先走旧 API，完全可以围绕新的分析式架构来设计。它的优点是：

- 与 Swift 结构化并发更契合
- 更适合实时 buffer 输入
- 资源预热、模型下载、结果流处理都有官方路径
- 更容易与本项目当前的 SwiftUI + async/await 代码风格保持一致

### 2.2 旧 API：SFSpeechRecognizer 只作为保底认知，不作为主实现

`SFSpeechRecognizer` 仍可用于语音识别，但官方文档强调了几个限制：

- 识别服务可用性并不恒定，需要检查 `isAvailable`
- 某些语言需要联网
- Apple 明确提醒存在“接近 1 分钟”的时长上限
- 官方文章《Asking Permission to Use Speech Recognition》强调该 API 会把语音发送到 Apple 服务器处理

对于聊天输入区，这些特性意味着：

- 长句输入体验容易被 1 分钟上限打断
- 网络与服务节流会直接影响可用性
- 隐私描述和权限流程更重

因此，本设计将 `SFSpeechRecognizer` 定位为 **对比对象与潜在未来兜底方案**，但不作为主架构基础。

### 2.3 音频采集层：AVAudioEngine 仍然是合理入口

Apple 的 `AVAudioEngine` 文档表明，它仍然是管理实时音频节点图、获取输入节点和启动/停止实时采集的基础设施。对于本项目最关键的是：

- 可以从 `inputNode` 获取麦克风输入
- 可以启动、停止和重置引擎
- 适合作为实时 buffer 生产端

结合 `SpeechAnalyzer` 文档，推荐做法是：

- 使用 `AVAudioEngine` 采集麦克风 PCM buffer
- 将 buffer 转换为 `SpeechAnalyzer.bestAvailableAudioFormat(...)` 返回的兼容格式
- 再包装成 `AnalyzerInput` 推送给 `SpeechAnalyzer`

### 2.4 权限与隐私键结论

Apple 官方文档明确给出了两个重要的隐私配置结论：

1. `NSMicrophoneUsageDescription` 是访问麦克风所必需的；没有它，使用麦克风 API 会失败。
2. `NSSpeechRecognitionUsageDescription` 是 `SFSpeechRecognizer.requestAuthorization` 和旧 Speech 识别 API 所要求的；缺失时调用相关 API 会崩溃。

因此本项目的配置建议是：

- **主方案仅使用 `SpeechAnalyzer` + 麦克风采集时，必须补 `NSMicrophoneUsageDescription`**。
- **如果代码中保留 `SFSpeechRecognizer` 兜底路径，再额外补 `NSSpeechRecognitionUsageDescription`**。

考虑到当前设计不打算首期引入旧 API 兜底，文档中的推荐是首期只接入麦克风权限和对应隐私文案；是否增加旧语音识别权限键，取决于后续是否真的链接并调用旧 API。

---

## 3. 现有代码基线

### 3.1 InputArea 当前结构

`ChatView+InputArea.swift` 中的输入区结构目前分为三层：

1. 上方辅助面板：slash / mention / todo
2. 中间上下文与状态行：provider badge、执行偏好、状态文本
3. 底部编辑区：`MentionAwareEditor` + `sendButton`

当前最关键的布局片段是：

- `MentionAwareEditor(text: $inputText, ...)`
- 右侧的 `sendButton`

这说明语音按钮最自然的集成位置有两个：

- 放到发送按钮左侧，作为同级输入动作按钮
- 合并到右侧操作区，形成“麦克风 / 停止录音 / 发送”动作簇

从现有布局和最小改动角度看，第二种更合适。

### 3.2 输入与发送语义

`ChatView+Actions.swift` 中的 `sendMessage()` 具备如下特征：

- 发送前对 `inputText` 做 trim
- 会拼接文件/选区上下文
- 会扩展 mention、审计输入指令
- 发送后清空 `inputText` 与附件

这意味着语音输入最稳妥的策略不是引入第二份“待发送语音文本”，而是将识别结果最终归并回 `inputText`，继续复用现有发送路径。

### 3.3 当前状态持有位置

`ChatView.swift` 已经持有大量输入区局部状态，例如：

- `inputText`
- `composerHeight`
- `errorMessage`
- `attachedFiles`
- slash / mention / directive 状态
- `@FocusState var isInputFocused`

这说明如果把语音输入的全部生命周期也直接塞进 `ChatView`，文件复杂度会继续上升。因此需要把语音状态与采集/转写逻辑抽出到独立组件。

### 3.4 工程配置现状

项目当前使用 `GENERATE_INFOPLIST_FILE = YES`，且 `project.pbxproj` 中还没有任何与麦克风或语音识别相关的 `INFOPLIST_KEY_*` 配置。`agentGui.entitlements` 中当前也只有 `com.apple.security.app-sandbox = false`。

这意味着首期落地前必须至少补充：

- 麦克风 usage description
- 对应的用户可见文案

---

## 4. 需求定义与非目标

### 4.1 功能需求

首期功能需求如下：

1. InputArea 增加一个麦克风按钮。
2. 点击后开始语音采集与实时转写，再次点击结束。
3. 录音期间按钮视觉状态必须明显变化。
4. 用户可以看到实时识别到的文本，而不是只能在结束后一次性得到结果。
5. 最终转写文本应并入当前 `inputText`，不绕开现有发送链路。
6. 录音失败、权限拒绝、设备不支持、模型未就绪时，需要有明确错误或提示。
7. 录音开始后，输入框仍应保持可聚焦和可编辑，但首期不要求“边打字边语音”做到复杂冲突合并。

### 4.2 非目标

首期不做以下能力：

- 连续对话式语音助手
- 自动发送消息
- 多语言自动检测
- 语音命令控制 slash / mention
- 音频文件持久化保存
- 波形可视化、VAD 强弱动画、音量计
- 旧 `SFSpeechRecognizer` 与新 `SpeechAnalyzer` 双栈并行上线

这里坚持 YAGNI：先把“稳定录音转文字并落到输入框”做完整。

---

## 5. 交互方案选型

### 5.1 方案 A：点击开始 / 点击结束，结果直接写入输入框

交互：

- 空闲时显示麦克风按钮
- 点击后进入录音态
- 实时转写结果直接反映到编辑器末尾
- 再次点击结束，保留最终文本
- 若取消或失败，可恢复录音前文本快照

优点：

- 最接近桌面聊天应用预期
- 用户能在原编辑器里直接看到结果
- 无需增加单独的转写面板

缺点：

- 需要处理“录音期间用户手动编辑”的冲突

### 5.2 方案 B：点击开始 / 点击结束，结果在独立预览条中展示

交互：

- 编辑器保持原始 `inputText`
- 实时转写结果显示在输入区上方或底部的预览条
- 结束后再一次性插入输入框

优点：

- 不会污染现有编辑器内容
- 冲突处理简单

缺点：

- 视觉层级更复杂
- 用户会觉得“明明在说话，但输入框没变化”
- 与 Apple 建议的“显示正在识别的文字”一致，但不够直接

### 5.3 方案结论

推荐采用 **方案 A**，但增加一个非常明确的实现约束：

> 录音开始时记录 `inputText` 快照，只允许语音结果以“尾部替换区”的方式更新；若用户在录音期间主动编辑到该区之外，首期直接停止录音并保留当前已识别内容，避免实现复杂的双向合并算法。

这样可以在保持直观体验的同时，控制实现复杂度。

---

## 6. 推荐架构

### 6.1 架构概览

推荐新增一个面向 UI 的轻量协调器，以及一个面向音频/分析流水线的底层会话对象：

1. `VoiceInputController`：`@MainActor @Observable`，负责 UI 状态、权限文案、错误、与 `ChatView` 的交互。
2. `SpeechCaptureSession`：负责 `AVAudioEngine`、`SpeechAnalyzer`、`SpeechTranscriber`、buffer 流和资源释放。

职责边界如下：

- `ChatView` 只关心“按钮怎么显示、录音何时开始结束、结果何时回写到 `inputText`”。
- `VoiceInputController` 负责状态机、快照、文本合并策略和用户可见错误。
- `SpeechCaptureSession` 负责麦克风音频采集、格式转换、模型预热、结果流消费。

### 6.2 推荐新增文件

建议新增如下文件：

- `agentGui/Models/VoiceInputPhase.swift`
- `agentGui/Services/VoiceInputController.swift`
- `agentGui/Services/SpeechCaptureSession.swift`
- `agentGui/Views/VoiceInputButton.swift`

建议修改如下文件：

- `agentGui/Views/ChatView.swift`
- `agentGui/Views/ChatView+InputArea.swift`
- `agentGui.xcodeproj/project.pbxproj`

### 6.3 VoiceInputController 设计

建议状态与接口如下：

```swift
@MainActor
@Observable
final class VoiceInputController {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case preparing
        case recording
        case finalizing
        case failed(String)
    }

    var phase: Phase = .idle
    var liveTranscript: String = ""
    var permissionHint: String?
    var startedAt: Date?

    func startRecording(currentText: String) async
    func stopRecording() async
    func cancelRecording() async
    func applyLiveTranscript(to text: inout String)
}
```

其中核心不是“暴露很多字段”，而是集中管理三件事：

- 录音前原始文本快照
- 实时转写文本
- 停止/取消时如何把结果并回编辑器

### 6.4 SpeechCaptureSession 设计

底层会话对象建议不直接依赖 SwiftUI，而是提供事件回调或异步流：

```swift
actor SpeechCaptureSession {
    struct Event {
        enum Kind {
            case partial(String)
            case final(String)
            case unavailable(String)
        }
        let kind: Kind
    }

    func start(locale: Locale) async throws -> AsyncThrowingStream<Event, Error>
    func stop() async throws
    func cancel() async
}
```

内部流程：

1. 检查 `SpeechTranscriber` 是否可用，并选择支持的 locale。
2. 通过 `AssetInventory` 检查是否需要下载/安装模型资源。
3. 使用 `SpeechAnalyzer.bestAvailableAudioFormat(...)` 确定兼容格式。
4. 创建 `AVAudioEngine`，从麦克风取流。
5. 将 buffer 转成 `AnalyzerInput` 并喂给 `SpeechAnalyzer`。
6. 消费 `transcriber.results`，推送 partial / final 事件。
7. 停止时调用 `finalizeAndFinish...`，并安全回收引擎与任务。

---

## 7. 状态模型与数据流

### 7.1 状态机

首期状态机建议如下：

- `idle`：空闲，可点击开始
- `requestingPermission`：等待麦克风授权
- `preparing`：初始化会话、资源预热、准备 analyzer
- `recording`：正在采集与接收 partial transcript
- `finalizing`：停止输入，等待最终 transcript flush
- `failed(message)`：失败态，按钮恢复空闲但可展示错误

状态迁移原则：

- 只有 `idle` 才能进入开始录音流程
- `recording` 和 `preparing` 才允许用户主动停止
- 任一异常都必须回到 `idle` 或 `failed`
- 不能出现两个并发录音会话

### 7.2 文本合并策略

首期推荐用“快照 + 可替换尾部”的策略：

1. 开始录音时记录 `baseInputText = inputText`。
2. partial transcript 到来时，渲染值使用：`baseInputText + separator + transcript`。
3. final transcript 到来后，把最终文本写回 `inputText`。
4. 如果用户在录音期间修改了 `baseInputText` 之前的部分，控制器直接停止录音，并保留已获得的当前文本。

推荐分隔策略：

- 若 `baseInputText` 为空，直接显示 transcript
- 若 `baseInputText` 非空且末尾不是空白，插入一个换行后再拼 transcript

这样可以避免把转写内容粘成一整段不可读文本。

### 7.3 与辅助输入系统的关系

`slash`、`mention`、`todo` 都依赖 `inputText` 的变化。首期应遵守以下规则：

- 录音开始时先关闭当前辅助面板
- partial transcript 仍然走现有 `updateComposerAssistState(_:)`
- 但语音输入不主动触发 slash 命令自动提交
- 若识别文本中包含 `@` 或 `/`，只允许出现候选，不自动选中

这是一个保守但稳定的策略，能避免“说一句话把 slash 面板顶出来并劫持输入焦点”的问题。

---

## 8. UI 集成设计

### 8.1 按钮位置

推荐把语音按钮放在 `sendButton` 的左侧，形成右下角动作簇：

- 空闲：`mic.fill`
- 录音中：`stop.circle.fill` 或 `mic.circle.fill` 的强调态
- 发送按钮保留原有箭头图标

按钮组优先级：

1. 录音控制
2. 停止流式输出
3. 发送消息

原因是语音输入属于“编辑动作”，更接近发送前的准备动作，而不是发送本身。

### 8.2 视觉反馈

Apple 旧 Speech 文档明确建议在录音期间给用户清晰提示，因此首期最少需要以下反馈：

- 麦克风按钮进入高亮态
- 输入区状态行出现“正在听写”文案
- 编辑器内实时显示识别文字

可选增强但非首期必须：

- 红点脉冲动画
- 已录音时长文本
- 轻量音量条

### 8.3 焦点与键盘行为

录音开始后：

- 保持 `MentionAwareEditor` 焦点，不主动失焦
- 不修改 `Command+Return` 发送快捷键
- `Escape` 若当前在录音态，优先解释为停止录音，而不是仅关闭辅助面板

这条规则可以减少用户的模式切换成本。

---

## 9. 权限、隐私与失败处理

### 9.1 权限策略

权限请求必须遵循 Apple 文档建议：**按首次使用时请求，而不是应用启动即请求。**

因此推荐流程为：

1. 用户第一次点击麦克风按钮
2. 若未授权，则请求麦克风权限
3. 授权成功后继续准备录音会话
4. 若拒绝，则给出带操作建议的错误文本

建议的 usage description 文案方向：

- `NSMicrophoneUsageDescription`: “agentGui 使用麦克风将你的语音实时转写为聊天输入内容，不会在未触发时持续录音。”

若未来增加旧语音识别兜底，再补：

- `NSSpeechRecognitionUsageDescription`: “agentGui 使用语音识别将你的语音转写为聊天输入内容，以便更快撰写消息。”

### 9.2 失败分类

首期失败建议分为以下几类：

- 权限拒绝
- 当前设备或 locale 不支持 `SpeechTranscriber`
- 模型资源不可下载或准备失败
- 麦克风输入初始化失败
- 分析过程中断

面向用户的提示原则：

- 错误文案短，不暴露底层类型名
- 必须附带下一步建议，例如“去系统设置开启麦克风权限”
- 不要把错误静默吞掉

### 9.3 隐私边界

本项目首期不保存原始音频，只处理瞬时转写结果。这是一个重要边界，应该写进实现和评审说明中：

- 不把 PCM buffer 落盘
- 不把音频作为附件加入会话
- 仅将最终文本进入 `inputText` 和现有消息发送链路

---

## 10. 实施拆分

### 阶段 1：能力接入

- 新增 `VoiceInputController`
- 新增 `SpeechCaptureSession`
- 在工程配置中补 `NSMicrophoneUsageDescription`
- 打通麦克风采集、实时 partial transcript、停止后的 final transcript

### 阶段 2：InputArea 集成

- 在 `ChatView` 中持有语音输入控制器状态
- 在 `ChatView+InputArea.swift` 中加入按钮与状态文案
- 让 live transcript 通过现有 `inputText` 渲染链路进入编辑器

### 阶段 3：交互收口

- 明确 `Escape`、再次点击、失败恢复等行为
- 处理录音期间手动编辑冲突
- 确保 slash / mention / todo 行为不被破坏

### 阶段 4：测试与验证

- 增加 controller 单测
- 增加输入区视图行为测试
- 手工验证权限、拒绝、停止、重复点击等边界情形

---

## 11. 测试策略

### 11.1 单元测试

建议优先测试 `VoiceInputController`，因为它承载了主要状态机与文本合并策略。重点覆盖：

- 从 `idle` 到 `recording` 的合法迁移
- partial transcript 如何覆盖尾部区域
- final transcript 如何固化回 `inputText`
- 取消录音如何恢复到开始前快照
- 手动编辑冲突如何触发停止或失败

### 11.2 集成测试

针对 `SpeechCaptureSession`，建议通过协议抽象注入假的 audio source 和 fake transcriber，而不是在测试里直接访问真实麦克风。这样可以验证：

- 会话启动与停止流程
- partial / final 事件顺序
- 错误能否正确上抛

### 11.3 UI 测试

首期 UI 测试不必真的录音，但应验证：

- 麦克风按钮是否出现
- 录音态的视觉标识是否变化
- 权限拒绝时是否展示预期提示
- 录音态与发送按钮、停止按钮是否没有冲突

---

## 12. 风险与权衡

### 12.1 录音期间编辑冲突

这是首期最大交互风险。如果用户边说边手工回改前文，实时 transcript 的“尾部替换”策略会变复杂。首期建议用保守策略处理：一旦检测到前置文本被改动，就停止当前录音会话并保留当前可见文本。

### 12.2 模型资源准备延迟

`SpeechAnalyzer` 路径可能需要模型资源安装或预热，首次点击的等待时间可能明显高于普通按钮交互。因此需要 `preparing` 态，而不能让按钮点击后“没有反馈”。

### 12.3 locale 支持差异

`SpeechTranscriber` 需要检查支持 locale。首期建议只尝试 `Locale.current` 对应的 supported locale；如果拿不到，直接提示当前系统语言暂不支持，而不是引入复杂的语言切换 UI。

### 12.4 不做旧 API 兜底的取舍

不做 `SFSpeechRecognizer` 首期兜底，会减少权限与网络复杂度，也更符合项目的 macOS 26 部署目标。但代价是：在新 API 资源不可用时，功能会直接降级为不可用，而不是自动回退到旧服务。这个取舍是有意的，目的是保持系统边界清晰。

---

## 13. 附录：参考资料

### Apple 官方文档

- Speech framework 概览
- SpeechAnalyzer
- SpeechTranscriber
- Bringing advanced speech-to-text capabilities to your app
- SFSpeechRecognizer
- Asking Permission to Use Speech Recognition
- AVAudioEngine
- NSMicrophoneUsageDescription

### 项目内相关文件

- `agentGui/Views/ChatView.swift`
- `agentGui/Views/ChatView+InputArea.swift`
- `agentGui/Views/ChatView+Actions.swift`
- `agentGui/agentGui.entitlements`
- `agentGui.xcodeproj/project.pbxproj`
