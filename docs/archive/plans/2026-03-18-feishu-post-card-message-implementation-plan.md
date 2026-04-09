# Feishu Post / Card Message Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add configurable Feishu outbound message formats so the app can send `text`, `post`, and `interactive` messages, with the default format selected in Settings and applied consistently to both create-message and reply-message flows.

**Architecture:** Keep the transport layer aligned with the official Lark IM v1 API: requests still go through the current create/reply endpoints, but the client stops being text-only. Introduce one small outbound rendering layer that converts agent plain text into Feishu-specific `msg_type + content` payloads, persist the selected default format on the channel binding, and let the Feishu adapter read that setting at send time.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation, Swift Testing, existing Feishu channel adapter/runtime, official Python SDK reference under `/Users/feint/Temp/feishu/venv/lib/python3.9/site-packages/lark_oapi/api/im/v1/model`.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. Design constraints

- Strict TDD. Every behavior starts with a failing test.
- Keep request shape aligned with the official SDK models:
  - `CreateMessageRequestBody(receive_id, msg_type, content, uuid)`
  - `ReplyMessageRequestBody(msg_type, content, reply_in_thread, uuid)`
- `content` must remain a JSON string, not a nested Swift `Encodable` object passed directly to the HTTP layer.
- Existing `text` behavior must remain the default for old saved data.
- Do not expand this work into card callback handling, raw JSON template editing, or non-text inbound parsing.
- Prefer a dedicated renderer/formatter layer over scattering `msg_type` branches through adapter and client code.
- Keep the runtime path stable: `RemoteAgentOrchestrator` should still emit plain text, and Feishu-specific rendering should happen only inside the Feishu adapter/client path.

## 1. Current codebase anchors

These are the main code paths this work will build on:

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/OutboundChannelMessage.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/ChannelRuntimeBootstrap.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/IMChannelModelTests.swift`
- `/Users/feint/Temp/feishu/venv/lib/python3.9/site-packages/lark_oapi/api/im/v1/model/create_message_request_body.py`
- `/Users/feint/Temp/feishu/venv/lib/python3.9/site-packages/lark_oapi/api/im/v1/model/reply_message_request_body.py`

## 2. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuMessageFormat.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuOutboundMessageRendererTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/IMChannelModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-18-feishu-channel-usage-manual.md`

## 3. Delivery strategy

Deliver this in five milestones:

1. Add a persistent Feishu outbound message format model with backward-compatible defaulting.
2. Add a dedicated renderer that turns plain text into `text`, `post`, and static `interactive` payload strings.
3. Generalize the Feishu client from text-only sending to message-format sending while keeping the same HTTP endpoints.
4. Wire the setting into the Feishu adapter and Settings UI.
5. Update usage docs and run focused regression tests.

Do not start by editing the UI. First lock the model and payload generation behavior with tests so the later UI and transport work only wires already-tested behavior together.

## 4. Task breakdown

### Task 1: Add persistent Feishu message format model

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuMessageFormat.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ChannelAccountBinding.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/IMChannelModelTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`

**Step 1: Write the failing tests**

Add tests that lock:

1. `FeishuMessageFormat` supports `.text`, `.post`, `.interactive`.
2. A new `ChannelAccountBinding` defaults to `.text` for Feishu if no explicit format is saved.
3. Old bindings that do not populate the new storage field still read back as `.text`.

Example test shape:

```swift
@Test func channelAccountBindingDefaultsFeishuMessageFormatToText() {
    let binding = ChannelAccountBinding(channelKind: .feishu, configurationKey: "feishu.default")

    #expect(binding.feishuMessageFormat == .text)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/IMChannelModelTests \
  -only-testing:agentGuiTests/ChannelSettingsViewModelTests
```

Expected: FAIL because `FeishuMessageFormat` and the new binding storage do not exist.

**Step 3: Write minimal implementation**

Implement:

1. `FeishuMessageFormat` enum with raw values matching Feishu message kinds.
2. A persisted raw-value field on `ChannelAccountBinding` for Feishu outbound format.
3. A computed property on `ChannelAccountBinding` that returns `.text` when the stored value is missing or invalid.

Keep this change narrowly scoped. Do not add other channel-specific settings yet.

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuMessageFormat.swift agentGui/Models/ChannelAccountBinding.swift agentGuiTests/IMChannelModelTests.swift agentGuiTests/ChannelSettingsViewModelTests.swift
git commit -m "feat: add feishu outbound message format model"
```

### Task 2: Add Feishu outbound payload renderer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuOutboundMessageRendererTests.swift`

**Step 1: Write the failing tests**

Add pure renderer tests for:

1. text format produces `msg_type == "text"` and `{"text":"..."}` content.
2. post format produces `msg_type == "post"` and wraps paragraphs under `zh_cn`.
3. interactive format produces `msg_type == "interactive"` and a static card payload containing title + body text.
4. multi-line plain text becomes multiple post paragraph nodes instead of one collapsed node.

Example test shape:

```swift
@Test func rendererBuildsPostPayloadFromMultilineText() throws {
    let payload = try FeishuOutboundMessageRenderer().render(
        text: "第一段\n\n第二段",
        format: .post,
        title: nil
    )

    #expect(payload.msgType == "post")
    #expect(payload.content.contains("zh_cn"))
    #expect(payload.content.contains("第一段"))
    #expect(payload.content.contains("第二段"))
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FeishuOutboundMessageRendererTests
```

Expected: FAIL because the renderer and rendered payload model do not exist.

**Step 3: Write minimal implementation**

Implement:

1. A small rendered payload type containing `msgType` and `content`.
2. `FeishuOutboundMessageRenderer.render(text:format:title:)`.
3. Minimal `post` JSON generation using `zh_cn` and paragraph blocks.
4. Minimal static `interactive` card generation with a simple title and one body area.

Do not add Markdown parsing, mention mapping, dynamic card buttons, or template editing.

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuOutboundMessageRenderer.swift agentGuiTests/FeishuOutboundMessageRendererTests.swift
git commit -m "feat: add feishu outbound payload renderer"
```

### Task 3: Generalize Feishu client send path

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuClientLiveTests.swift`

**Step 1: Write the failing tests**

Extend `FeishuClientLiveTests` to prove:

1. create-message requests can send `text`, `post`, and `interactive`.
2. reply-message requests can send `text`, `post`, and `interactive`.
3. the request body still matches the official SDK contract: `msg_type` and stringified `content`.

Example test shape:

```swift
@Test func sendMessageUsesInteractiveMsgTypeForReply() async throws {
    // arrange stub transport responses
    // start client
    // call generalized send API with rendered interactive payload
    // assert request body contains "msg_type":"interactive"
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/FeishuClientLiveTests
```

Expected: FAIL because the client only exposes `sendText(...)`.

**Step 3: Write minimal implementation**

Refactor `FeishuClient` and `LiveFeishuClient` to:

1. replace text-only public sending with a generalized send API that accepts rendered `msgType` and `content`.
2. keep the same create and reply endpoints.
3. reuse existing token caching and HTTP validation.
4. keep existing text behavior as a convenience path only if the tests still need it, otherwise remove the text-only method and update all callers.

Do not change token fetching logic, long connection logic, or response parsing shape.

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuClient.swift agentGuiTests/FeishuClientLiveTests.swift
git commit -m "feat: generalize feishu outbound send api"
```

### Task 4: Wire format selection into adapter and settings state

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ChannelSettingsViewModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/Settings/SettingsChannelsView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/FeishuChannelAdapterTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ChannelSettingsViewModelTests.swift`

**Step 1: Write the failing tests**

Add tests that prove:

1. `ChannelSettingsViewModel.save()` persists the selected Feishu message format.
2. `ChannelSettingsViewModel.load()` restores the saved format.
3. `FeishuChannelAdapter.send(...)` reads `configuration.accountBinding.feishuMessageFormat` and uses the renderer before sending.
4. adapter send behavior differs correctly between `.text`, `.post`, and `.interactive`.

Example test shape:

```swift
@Test func saveFeishuSettingsPersistsSelectedMessageFormat() throws {
    let harness = try ChannelSettingsHarness.make()
    harness.viewModel.feishuMessageFormat = .interactive

    try harness.viewModel.save()

    let binding = try #require(try harness.context.fetch(FetchDescriptor<ChannelAccountBinding>()).first)
    #expect(binding.feishuMessageFormat == .interactive)
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/ChannelSettingsViewModelTests \
  -only-testing:agentGuiTests/FeishuChannelAdapterTests
```

Expected: FAIL because the view model and adapter do not know about the new format.

**Step 3: Write minimal implementation**

Implement:

1. `ChannelSettingsViewModel.feishuMessageFormat` with load/save wiring.
2. A Settings UI picker inside the existing Feishu section.
3. `FeishuChannelAdapter` renderer injection and send-time format lookup from `configuration.accountBinding`.
4. A simple card title policy, for example using the saved display name when non-empty, otherwise a fixed fallback title.

Keep the adapter’s inbound behavior unchanged.

**Step 4: Run tests to verify they pass**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Channels/Adapters/Feishu/FeishuChannelAdapter.swift agentGui/ViewModels/ChannelSettingsViewModel.swift agentGui/Views/Settings/SettingsChannelsView.swift agentGuiTests/FeishuChannelAdapterTests.swift agentGuiTests/ChannelSettingsViewModelTests.swift
git commit -m "feat: add feishu message format setting"
```

### Task 5: Run focused regressions and update operator docs

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-18-feishu-channel-usage-manual.md`

**Step 1: Write the doc delta**

Update the usage manual so it no longer claims the product only supports text sending. Document:

1. the new Settings option,
2. the three outbound formats,
3. the fact that card messages are static display cards only.

**Step 2: Run focused regression tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/IMChannelModelTests \
  -only-testing:agentGuiTests/ChannelSettingsViewModelTests \
  -only-testing:agentGuiTests/FeishuOutboundMessageRendererTests \
  -only-testing:agentGuiTests/FeishuClientLiveTests \
  -only-testing:agentGuiTests/FeishuChannelAdapterTests \
  -only-testing:agentGuiTests/ChannelRuntimeBootstrapTests
```

Expected: PASS.

If the repo is stable enough, then run the smoke task:

```bash
./scripts/run_quality_smoke.sh
```

If unrelated failures appear, record them and do not expand scope to fix unrelated issues.

**Step 3: Manual verification**

In the app:

1. Open Settings -> 渠道 -> 飞书.
2. Confirm the new format selector defaults to 文本消息 for a fresh/old binding.
3. Save `Post 富文本`, reopen Settings, and confirm it persists.
4. Save `卡片消息`, reopen Settings, and confirm it persists.

In a real Feishu environment:

1. verify a plain text reply displays as text,
2. verify a `post` reply renders as rich text,
3. verify an `interactive` reply renders as a static card.

**Step 4: Commit**

```bash
git add docs/spec/2026-03-18-feishu-channel-usage-manual.md
git commit -m "docs: document feishu outbound message formats"
```

## 5. Execution notes

- Prefer deleting `sendText(...)` entirely once all tests and call sites move to the generalized send path. Keeping both APIs is only acceptable if it materially reduces churn during the migration.
- Keep `OutboundChannelMessage` plain-text-only unless a real second channel needs structured outbound content. The Feishu adapter already has enough context to render plain text into a Feishu-specific payload.
- If `ChannelAccountBinding` feels too generic for a Feishu-specific raw-value field, use a generic outbound-format storage name but keep the initial enum/behavior Feishu-focused. Do not introduce a second persistence model just for this requirement.
- If UI test coverage is missing for the Settings picker, rely on strong view model tests plus one manual verification pass instead of inventing a new UI testing stack.

## 6. Acceptance checklist

- Old saved bindings load with `text` as the default Feishu message format.
- Settings can persist and restore `text`, `post`, and `interactive`.
- Renderer outputs valid `msg_type + content` pairs for all three formats.
- Feishu create-message requests send the selected format.
- Feishu reply-message requests send the selected format.
- Existing inbound Feishu behavior remains unchanged.
- Docs no longer claim outbound text is the only supported format.

Plan complete and saved to `docs/plans/2026-03-18-feishu-post-card-message-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?