# ChatView Agent Message UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild ChatView agent messages into an execution-order-first flow with lighter thinking/tool visuals, operation-specific step rows, auto-expand while running, auto-collapse after completion, and preserved subagent task cards.

**Architecture:** Introduce a small presentation layer that converts `Message`, `AgentRound`, and `ToolCall` into a flat ordered step snapshot before SwiftUI renders anything. Keep the view layer thin: `MessageBubbleView` should render a chronological step list, `ThinkingBubbleView` and `ToolCallBubbleView` should become lightweight row renderers, and `SubagentTaskCardView` should stay as the only clearly card-like nested artifact in the main flow.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `Message` / `AgentRound` / `ToolCall` models.

---

## Implementation Notes

- This plan implements the requirements in [docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md](/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md).
- Use the structural examples in [docs/spec/2026-03-10-chatview-agent-message-ui-wireframes.md](/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-chatview-agent-message-ui-wireframes.md) as the visual contract.
- Do not push formatting or expansion rules into SwiftUI view bodies. Keep them in a presentation layer under `agentGui/ViewModels/`.
- Follow TDD where practical: presentation snapshots, ordering, status transitions, and tool-specific row metadata should be pinned by tests first.
- For pure layout tasks, use compile checks plus manual smoke tests in the running app.
- Keep `SubagentTaskCardView` as a special-case card. Everything else in the primary flow should trend toward flat rows, not nested framed blocks.

## Proposed File Layout

**Create presentation layer:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`

**Create tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Modify primary views:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ThinkingBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTaskCardView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTimelineView.swift`

**Create flow-specific view helpers if needed:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageStepFlowView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageResultBlockView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`

**Likely simplify or bypass in the main path:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ExecutionSummaryBarView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactDrawerView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentAnswerCardView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentStepTimelineView.swift`

## Task 1: Build the Flat Flow Presentation Contract

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Message.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentRound.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`

**Step 1: Write the failing tests**

Add tests that pin the flow contract:

- `flowSnapshotOrdersMessageRoundAndToolStepsChronologically()`
- `flowSnapshotKeepsResultBlocksInExecutionOrder()`
- `flowSnapshotMarksOnlyActiveStepExpandedWhileRunning()`
- `flowSnapshotCollapsesCompletedStepsByDefault()`
- `flowSnapshotPreservesSubagentAsDedicatedStepKind()`

Example assertion shape:

```swift
@Test func flowSnapshotMarksOnlyActiveStepExpandedWhileRunning() async throws {
    let message = AgentMessageFlowFixture.makeRunningMessage()

    let snapshot = AgentMessageFlowPresentation.snapshot(for: message)

    #expect(snapshot.steps.filter(\.isExpanded).count == 1)
    #expect(snapshot.steps.last?.isExpanded == true)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: FAIL because the presentation type does not exist yet.

**Step 3: Write minimal implementation**

Create a presentation API that flattens message content into renderable steps:

```swift
struct AgentMessageFlowSnapshot: Equatable {
    let messageID: UUID
    let steps: [AgentMessageFlowStep]
}

enum AgentMessageFlowStep: Equatable, Identifiable {
    case result(ResultStepPresentation)
    case thinking(ThinkingStepPresentation)
    case tool(ToolStepPresentation)
    case subagent(SubagentStepPresentation)
}
```

Build steps from:

- `message.textContent`
- `message.agentRounds`
- message-level `toolCalls`
- round-level `toolCalls`

Sort them in execution order using timestamps and round index fallbacks.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "feat: add agent message flow presentation"
```

## Task 2: Add Tool-Specific Row Presentation Metadata

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/Enums.swift`

**Step 1: Write the failing tests**

Add tests that pin operation-specific metadata:

- `readToolUsesFileFocusedRowPresentation()`
- `editToolUsesChangeSummaryRowPresentation()`
- `executeToolUsesCommandRowPresentation()`
- `searchToolUsesQueryRowPresentation()`
- `askUserToolUsesQuestionAnswerRowPresentation()`
- `failedExecuteToolExposesFailureSummaryWithoutFullOutput()`

Example:

```swift
@Test func editToolUsesChangeSummaryRowPresentation() async throws {
    let tool = AgentMessageFlowFixture.makeEditToolCall()

    let row = ToolCallRowPresentation.make(for: tool)

    #expect(row.style == .edit)
    #expect(row.primaryText == "MessageBubbleView.swift")
    #expect(row.secondaryText == "2 处变更")
}
```

**Step 2: Run test to verify it fails**

Run the same focused test command.

Expected: FAIL because the row presentation type does not exist.

**Step 3: Write minimal implementation**

Add row-level metadata that the view can render directly:

```swift
enum ToolRowStyle: Equatable {
    case read
    case edit
    case execute
    case search
    case fetch
    case askUser
    case other
}

struct ToolCallRowPresentation: Equatable {
    let style: ToolRowStyle
    let primaryText: String
    let secondaryText: String?
    let tertiaryText: String?
    let statusText: String
    let isExpanded: Bool
    let detailText: String?
}
```

Keep this logic out of the view layer.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "feat: add tool-specific step row presentation"
```

## Task 3: Refactor ThinkingBubbleView into a Lightweight Step Row

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ThinkingBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`

**Step 1: Run build to verify the current baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 2: Write minimal implementation**

Change `ThinkingBubbleView` from a high-contrast card to a compact step row:

- shallow background or divider treatment
- reduced color emphasis
- collapsed by default when completed
- expanded only when explicitly requested or when the presentation says it is active

Prefer an initializer driven by presentation data rather than raw `String` only, for example:

```swift
struct ThinkingBubbleView: View {
    let presentation: ThinkingStepPresentation
}
```

**Step 3: Run build to verify it compiles**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke test**

Open the app and verify:

- completed thinking rows render as one compact line
- active thinking rows expand without a thick purple frame
- completed thinking rows auto-collapse after status transitions

**Step 5: Commit**

```bash
git add agentGui/Views/ThinkingBubbleView.swift agentGui/Views/MessageBubbleView.swift
git commit -m "feat: simplify thinking rows in agent message flow"
```

## Task 4: Refactor ToolCallBubbleView into Operation-Specific Step Rows

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`

**Step 1: Run build to verify the current baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 2: Write minimal implementation**

Refactor `ToolCallBubbleView` so it renders as a flat row with per-style detail blocks:

- read rows emphasize filename and path
- edit rows emphasize file + change summary
- execute rows emphasize command + concise result
- search/fetch rows emphasize query or URL + result count
- ask-user rows emphasize question + answer summary

Move verbose content into `ToolCallDetailContentView` and only show it when `presentation.isExpanded == true`.

**Step 3: Run build to verify it compiles**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke test**

Verify with sample messages that:

- active command rows expand and show live output
- completed command rows collapse back to a single summary line
- read/edit/search rows each look semantically different
- no row introduces a heavy nested outline box

**Step 5: Commit**

```bash
git add agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/Views/MessageBubbleView.swift
git commit -m "feat: add operation-specific tool step rows"
```

## Task 5: Rebuild MessageBubbleView as a Sequential Agent Step Flow

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/MessageBubbleView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageStepFlowView.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentMessageResultBlockView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ChatView+MessageList.swift`
- Likely bypass: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ExecutionSummaryBarView.swift`
- Likely bypass: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ArtifactDrawerView.swift`
- Likely bypass: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentAnswerCardView.swift`
- Likely bypass: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/AgentStepTimelineView.swift`

**Step 1: Run build to establish the pre-refactor baseline**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 2: Write minimal implementation**

Introduce a flow view that renders `AgentMessageFlowSnapshot.steps` in order:

```swift
struct AgentMessageStepFlowView: View {
    let snapshot: AgentMessageFlowSnapshot
}
```

Render by step kind:

- `.result` -> `AgentMessageResultBlockView`
- `.thinking` -> `ThinkingBubbleView`
- `.tool` -> `ToolCallBubbleView`
- `.subagent` -> `SubagentTaskCardView`

Update `MessageBubbleView` so agent messages use this flow as the main content path.

**Step 3: Run build to verify it compiles**

Run the same build command.

Expected: BUILD SUCCESS.

**Step 4: Manual smoke test**

In the app, verify:

- agent messages read top-to-bottom as chronological steps
- result blocks can appear between process rows and at the end
- the old summary bar / artifact drawer path is no longer the primary agent experience

**Step 5: Commit**

```bash
git add agentGui/Views/MessageBubbleView.swift agentGui/Views/AgentMessageStepFlowView.swift agentGui/Views/AgentMessageResultBlockView.swift agentGui/Views/ChatView+MessageList.swift agentGui/Views/ExecutionSummaryBarView.swift agentGui/Views/ArtifactDrawerView.swift agentGui/Views/AgentAnswerCardView.swift agentGui/Views/AgentStepTimelineView.swift
git commit -m "feat: rebuild agent messages as sequential step flow"
```

## Task 6: Align Subagent Task Cards with the New Flow Rules

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTaskCardView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/SubagentTimelineView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/AgentMessageFlowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests for subagent presentation behavior:

- `subagentStepUsesTaskCardPresentation()`
- `subagentStepExpandsOnlyWhileRunningByDefault()`
- `subagentStepCollapsesAfterCompletion()`
- `subagentStepKeepsTimelineHiddenUntilExplicitDetailsMode()`

Example:

```swift
@Test func subagentStepCollapsesAfterCompletion() async throws {
    let message = AgentMessageFlowFixture.makeCompletedSubagentMessage()

    let snapshot = AgentMessageFlowPresentation.snapshot(for: message)
    let subagent = try #require(snapshot.steps.compactMap { step -> SubagentStepPresentation? in
        guard case .subagent(let value) = step else { return nil }
        return value
    }.first)

    #expect(subagent.isExpanded == false)
}
```

**Step 2: Run test to verify it fails**

Run the same focused test command.

Expected: FAIL until the subagent presentation logic is updated.

**Step 3: Write minimal implementation**

Update subagent rendering so:

- the default flow item is a concise task card
- running state may expand automatically
- completion returns to summary mode
- full timeline remains behind an explicit “查看完整执行过程” action

Do not make subagent rows look like the flat tool rows; keep a lighter card treatment.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/SubagentTaskCardView.swift agentGui/Views/SubagentTimelineView.swift agentGui/ViewModels/AgentMessageFlowPresentation.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "feat: align subagent task cards with step flow"
```

## Task 7: Full Regression Pass and Cleanup

**Files:**
- Modify any touched files from previous tasks as needed
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-chatview-agent-message-ui-requirements.md`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-chatview-agent-message-ui-wireframes.md`

**Step 1: Run the focused presentation tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: TEST SUCCEEDED.

**Step 2: Run the full test suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test
```

Expected: TEST SUCCEEDED.

**Step 3: Run the full app build**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 4: Manual smoke test the key scenarios**

Verify these scenarios in the app:

- agent reads files only
- agent edits a file
- agent runs a command with streaming output
- agent hits a failed command
- agent invokes a subagent
- agent asks the user a question
- a long execution auto-collapses after completion

**Step 5: Commit**

```bash
git add agentGui/ViewModels agentGui/Views agentGuiTests
git commit -m "feat: ship execution-order-first agent message ui"
```

Plan complete and saved to `docs/plans/2026-03-10-chatview-agent-message-ui.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?