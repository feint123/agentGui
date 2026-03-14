# BashTool Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild BashTool into a managed terminal-task runtime that can auto-classify commands, scan task state continuously, auto-handle safe interactive prompts, and manage background jobs with structured UI-visible state.

**Architecture:** Keep the existing persistent `zsh` session as the low-level execution transport for this iteration, but add a new runtime layer above it: pure task models, a command classifier, a scan/event reducer, a task registry, and an interaction policy bridge. Persist only the minimum task metadata into `ToolCall` so the chat UI can show task-level state without immediately requiring a full terminal subsystem rewrite or PTY migration.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, existing `ClaudeService` tool dispatch, current `BashSession` actor.

---

## Implementation Notes

- This plan implements the requirements in [docs/spec/2026-03-10-bash-tool-redesign-requirements.md](/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-bash-tool-redesign-requirements.md).
- Keep the first delivery on top of the current `Process + Pipe` transport. PTY support is explicitly deferred unless a blocking incompatibility appears during implementation.
- Prefer pure, testable reducers and analyzers before changing `ClaudeService` orchestration.
- Use TDD for classifier logic, prompt detection, event reduction, schema generation, and presentation logic.
- Keep the migration incremental: support legacy `background` / `interactive` / `interrupt` inputs while introducing the new action model.
- Commit after each task.

## Proposed File Layout

**Create runtime models and services:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashCommandClassifier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskEventReducer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskRegistry.swift`

**Modify runtime integration points:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashSession.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`

**Modify persistence and presentation:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`

**Create tests:**
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskModelsTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashCommandClassifierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashTaskEventReducerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

## Task 1: Add Terminal Task Domain Models

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskModelsTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`

**Step 1: Write the failing tests**

Add tests for the task domain contract:

```swift
import Testing
@testable import agentGui

struct TerminalTaskModelsTests {
    @Test func statusKnowsWhetherTaskIsTerminal() async throws {
        #expect(TerminalTaskStatus.completed.isTerminal)
        #expect(!TerminalTaskStatus.runningForeground.isTerminal)
    }

    @Test func promptSnapshotMasksSensitiveKinds() async throws {
        let snapshot = TerminalPromptSnapshot(
            kind: .secret,
            promptText: "Password:",
            options: [],
            recommendedReply: nil
        )

        #expect(snapshot.shouldMaskReply)
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TerminalTaskModelsTests
```

Expected: FAIL because the terminal task model types do not exist.

**Step 3: Write minimal implementation**

Create the shared runtime types as pure models:

```swift
enum TerminalExecutionMode: String, Codable {
    case auto, foreground, background, interactive
}

enum TerminalTaskStatus: String, Codable {
    case queued
    case classifying
    case launching
    case runningForeground
    case waitingForPrompt
    case runningBackground
    case completed
    case failed
    case interrupted
    case timedOut
    case needsUserDecision

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted, .timedOut:
            return true
        default:
            return false
        }
    }
}

enum TerminalPromptKind: String, Codable {
    case yesNo
    case singleChoice
    case multiChoice
    case textInput
    case pathInput
    case pressEnter
    case secret
    case destructiveConfirmation
    case unknown
}
```

Also define `TerminalTaskSnapshot`, `TerminalPromptSnapshot`, `TerminalTaskEvent`, and `TerminalRiskLevel`.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TerminalTaskModels.swift agentGuiTests/TerminalTaskModelsTests.swift
git commit -m "feat: add terminal task runtime models"
```

## Task 2: Build the Command Classifier

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashCommandClassifier.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashCommandClassifierTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`

**Step 1: Write the failing tests**

Add tests that pin the classification contract:

```swift
import Testing
@testable import agentGui

struct BashCommandClassifierTests {
    @Test func classifiesDevServerAsBackgroundCandidate() async throws {
        let result = BashCommandClassifier().classify(
            command: "npm run dev",
            goalHint: "启动服务并继续编码"
        )

        #expect(result.classification == .background)
        #expect(result.confidence > 0.5)
    }

    @Test func classifiesCreateCommandAsInteractive() async throws {
        let result = BashCommandClassifier().classify(
            command: "npx create-next-app demo",
            goalHint: "初始化项目"
        )

        #expect(result.classification == .interactive)
    }
}
```

Also add tests for `git commit`, `python`, `xcodebuild test`, and unknown commands.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashCommandClassifierTests
```

Expected: FAIL because the classifier does not exist.

**Step 3: Write minimal implementation**

Create a classifier result model and rule-based first pass:

```swift
struct BashCommandClassificationResult: Equatable {
    let classification: TerminalCommandClassification
    let executionMode: TerminalExecutionMode
    let confidence: Double
    let reasons: [String]
}

enum TerminalCommandClassification: String, Codable {
    case foreground
    case background
    case interactive
    case interactiveBackgroundBootstrap
    case monitorOnly
    case unknown
}
```

Use a layered decision order:

- explicit overrides
- known interactive patterns
- known background/watch/server patterns
- goal-hint heuristics
- unknown fallback

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/BashCommandClassifier.swift agentGuiTests/BashCommandClassifierTests.swift
git commit -m "feat: add bash command classifier"
```

## Task 3: Add Prompt Analyzer and Safety Gate

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AskUserQuestion.swift`

**Step 1: Write the failing tests**

Add tests for prompt parsing and escalation:

```swift
import Testing
@testable import agentGui

struct BashPromptAnalyzerTests {
    @Test func detectsYesNoPrompt() async throws {
        let snapshot = BashPromptAnalyzer().analyze(output: "Proceed? (y/N)")

        #expect(snapshot?.kind == .yesNo)
        #expect(snapshot?.recommendedReply == "n")
    }

    @Test func marksPasswordPromptAsNeedsUserDecision() async throws {
        let snapshot = BashPromptAnalyzer().analyze(output: "Password:")

        #expect(snapshot?.kind == .secret)
        #expect(snapshot?.shouldAutoReply == false)
    }
}
```

Also add tests for numbered menus, overwrite prompts, and enter-to-continue prompts.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashPromptAnalyzerTests
```

Expected: FAIL because the prompt analyzer does not exist.

**Step 3: Write minimal implementation**

Implement prompt analysis as a pure service returning `TerminalPromptSnapshot` plus policy hints:

```swift
struct TerminalPromptDecision: Equatable {
    let snapshot: TerminalPromptSnapshot
    let shouldAutoReply: Bool
    let autoReplyText: String?
    let escalationReason: String?
}
```

Support at least:

- yes/no
- single choice
- path/text input
- overwrite confirmation
- secret prompts
- destructive confirmation

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/BashPromptAnalyzer.swift agentGuiTests/BashPromptAnalyzerTests.swift
git commit -m "feat: add bash prompt analyzer"
```

## Task 4: Add the Scan/Event Reducer

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskEventReducer.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashTaskEventReducerTests.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`

**Step 1: Write the failing tests**

Add reducer tests that convert raw runtime observations into structured events:

```swift
import Testing
@testable import agentGui

struct BashTaskEventReducerTests {
    @Test func emitsWaitingForPromptWhenOutputGoesIdleAndPromptDetected() async throws {
        let reducer = BashTaskEventReducer()
        let previous = TerminalTaskSnapshot.fixture(status: .runningForeground)
        let observation = TerminalTaskObservation(
            appendedOutput: "Install dependencies? (Y/n)",
            processIsAlive: true,
            idleDuration: 1.2,
            promptDecision: .fixture(kind: .yesNo)
        )

        let update = reducer.reduce(previous: previous, observation: observation)

        #expect(update.snapshot.status == .waitingForPrompt)
        #expect(update.events.contains { $0.kind == .promptDetected })
    }
}
```

Also add tests for background registration, process exit success, process exit failure, timeout, and unknown prompt cases.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashTaskEventReducerTests
```

Expected: FAIL because the reducer and observation types do not exist.

**Step 3: Write minimal implementation**

Create a pure reducer API:

```swift
struct TerminalTaskObservation {
    let appendedOutput: String
    let processIsAlive: Bool
    let idleDuration: TimeInterval
    let promptDecision: TerminalPromptDecision?
}

struct TerminalTaskReduction {
    let snapshot: TerminalTaskSnapshot
    let events: [TerminalTaskEvent]
}
```

Implement state transitions for:

- launch -> running foreground
- running -> waiting for prompt
- running -> completed / failed
- running -> timed out
- running foreground -> running background
- waiting for prompt -> needs user decision

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/BashTaskEventReducer.swift agentGuiTests/BashTaskEventReducerTests.swift
git commit -m "feat: add terminal task event reducer"
```

## Task 5: Introduce the Task Registry and BashSession Runtime Bridge

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashTaskRegistry.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashSession.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskModelsTests.swift`

**Step 1: Write the failing tests**

Add tests for registry behavior:

```swift
@Test func registryStoresAndUpdatesTaskSnapshots() async throws {
    let registry = BashTaskRegistry()
    let task = TerminalTaskSnapshot.fixture(id: "task-1", status: .queued)

    await registry.upsert(task)
    await registry.updateStatus(taskId: "task-1", status: .runningForeground)

    let loaded = await registry.snapshot(taskId: "task-1")
    #expect(loaded?.status == .runningForeground)
}
```

Also add a test proving each `ClaudeService` session gets a registry-backed task namespace.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/TerminalTaskModelsTests
```

Expected: FAIL because the registry does not exist.

**Step 3: Write minimal implementation**

Add `BashTaskRegistry` as an actor keyed by `taskId`, with methods to:

- create task
- upsert snapshot
- append event
- list active background tasks
- mark task complete

Extend `ClaudeService` storage with a per-session registry map similar to `bashSessions`, and extend `BashSession` with minimal runtime helpers:

- current process alive status
- current command output delta
- signal support for interrupt / terminate

Do not attempt a full `BashSession` rewrite in this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/BashTaskRegistry.swift agentGui/Services/BashSession.swift agentGui/Services/ACPClientService.swift agentGui/Services/ClaudeService+BashSession.swift agentGuiTests/TerminalTaskModelsTests.swift
git commit -m "feat: add bash task registry"
```

## Task 6: Rework Bash Tool Schema and Dispatch

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolDispatch.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolSchemaTests.swift`

**Step 1: Write the failing tests**

Add tests for the new schema and compatibility behavior:

```swift
import Testing
@testable import agentGui

struct BashToolSchemaTests {
    @Test func toolBuilderExposesManagedTaskFields() async throws {
        let settings = AppSettings()
        settings.enableBashTool = true

        let tools = ClaudeService().buildTools(modelId: "claude-sonnet-4-6", settings: settings)
        let bash = try #require(toolNamed("bash", in: tools))

        #expect(schemaPropertyNames(from: bash).contains("execution_mode"))
        #expect(schemaPropertyNames(from: bash).contains("task_id"))
        #expect(schemaPropertyNames(from: bash).contains("signal"))
        #expect(schemaPropertyNames(from: bash).contains("goal_hint"))
    }
}
```

Also add a dispatch-focused test for legacy `background: true` mapping to the new runtime action.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashToolSchemaTests
```

Expected: FAIL because the schema fields are not present.

**Step 3: Write minimal implementation**

Update the bash tool description and schema to add:

- `execution_mode`
- `task_id`
- `signal`
- `goal_hint`
- `scan_policy`
- `auto_reply_policy`

In `executeBashTool`, normalize legacy inputs into a single runtime request object, for example:

```swift
struct BashToolRequest {
    let command: String?
    let taskId: String?
    let executionMode: TerminalExecutionMode
    let input: String?
    let signal: TerminalSignal?
    let goalHint: String?
    let autoReplyPolicy: TerminalAutoReplyPolicy
}
```

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ClaudeService+BashTool.swift agentGui/Services/ClaudeService+ToolDispatch.swift agentGuiTests/BashToolSchemaTests.swift
git commit -m "feat: add managed bash tool schema"
```

## Task 7: Connect Auto-Reply and User Escalation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AskUserQuestion.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashSession.swift`
- Reference: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`

**Step 1: Write the failing tests**

Add tests covering the two core branches:

```swift
@Test func safePromptCanAutoReply() async throws {
    let decision = TerminalPromptDecision.fixture(kind: .yesNo, shouldAutoReply: true, autoReplyText: "y")

    #expect(decision.shouldAutoReply)
    #expect(decision.autoReplyText == "y")
}

@Test func secretPromptEscalatesToUserQuestion() async throws {
    let decision = TerminalPromptDecision.fixture(kind: .secret, shouldAutoReply: false, autoReplyText: nil)

    #expect(decision.escalationReason == "sensitive-input")
}
```

Then add an integration-style test that transforms a `TerminalPromptDecision` into an `ask_user_question` payload.

**Step 2: Run test to verify it fails**

Run the relevant focused test command.

Expected: FAIL because the escalation bridge does not exist.

**Step 3: Write minimal implementation**

Implement the interaction bridge in `executeBashTool`:

- if prompt is safe and auto-reply is enabled, send input back into `BashSession`
- if prompt is unsafe, build a structured user question and suspend on the existing `ask_user_question` mechanism
- after user reply, continue the original terminal task instead of spawning a new command

Keep the first version synchronous within the current task loop. Do not introduce a second conversation channel yet.

**Step 4: Run test to verify it passes**

Run the focused tests again.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+BashTool.swift agentGui/Services/ClaudeService+AskUserQuestion.swift agentGui/Services/BashSession.swift agentGuiTests/BashPromptAnalyzerTests.swift
git commit -m "feat: bridge bash prompts to auto-reply and user escalation"
```

## Task 8: Persist Task Metadata into ToolCall and Update Live Polling

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolCallRecord.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentMessageFlowPresentationTests.swift`

**Step 1: Write the failing tests**

Add tests or extend existing presentation fixtures to assert bash task metadata is preserved:

```swift
@Test func runningExecuteToolPreservesTaskStatusMetadata() async throws {
    let tool = ToolCall(toolCallId: "exec-1", kind: .execute)
    tool.title = "npm run dev"
    tool.terminalTaskId = "task-1"
    tool.terminalTaskStatus = "runningBackground"
    tool.terminalPromptSummary = "Listening on http://localhost:3000"

    let row = ToolCallRowPresentation.make(for: tool)

    #expect(row.statusText == "后台运行中")
    #expect(row.tertiaryText == "Listening on http://localhost:3000")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: FAIL because the new `ToolCall` fields and presentation mapping do not exist.

**Step 3: Write minimal implementation**

Add optional `ToolCall` fields using migration-friendly storage:

- `terminalTaskId: String?`
- `terminalTaskStatus: String?`
- `terminalPromptSummary: String?`
- `terminalAgentActionsJSON: String?`
- `terminalExecutionMode: String?`

Update `makeToolCallRecord` and live polling in `ClaudeService+AgenticLoop` so bash tool records keep structured task metadata alongside the raw transcript.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ToolCall.swift agentGui/Services/ClaudeService+ToolCallRecord.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentMessageFlowPresentationTests.swift
git commit -m "feat: persist bash task metadata on tool calls"
```

## Task 9: Update Tool Call Presentation for Managed Terminal Tasks

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`

**Step 1: Write the failing tests**

Add tests for background-state and prompt-state rendering:

```swift
import Testing
@testable import agentGui

struct BashToolCallPresentationTests {
    @Test func runningBackgroundTaskShowsManagedSummary() async throws {
        let tool = ToolCall(toolCallId: "exec-1", kind: .execute)
        tool.title = "npm run dev"
        tool.terminalExecutionMode = "background"
        tool.terminalTaskStatus = "runningBackground"
        tool.terminalPromptSummary = "http://localhost:3000"

        let row = ToolCallRowPresentation.make(for: tool)

        #expect(row.secondaryText == "后台运行中")
        #expect(row.tertiaryText == "http://localhost:3000")
    }
}
```

Also add a case for `needsUserDecision` and one for auto-replied yes/no prompts.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: FAIL because presentation logic is not task-aware.

**Step 3: Write minimal implementation**

Extend `ToolCallRowPresentation` so execute rows derive summary from managed task metadata before falling back to raw terminal text. Update the views to surface:

- current mode
- task status badge
- prompt summary
- latest auto-reply summary
- expanded transcript

Keep the UI shallow. Do not build a new terminal panel in this task.

**Step 4: Run test to verify it passes**

Run the same focused test command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/ViewModels/ToolCallRowPresentation.swift agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGuiTests/BashToolCallPresentationTests.swift
git commit -m "feat: show managed bash task state in tool call UI"
```

## Task 10: Full Regression Pass and Documentation Cleanup

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/spec/2026-03-10-bash-tool-redesign-requirements.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/README.md`

**Step 1: Run focused tests for the full bash redesign slice**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalTaskModelsTests \
  -only-testing:agentGuiTests/BashCommandClassifierTests \
  -only-testing:agentGuiTests/BashPromptAnalyzerTests \
  -only-testing:agentGuiTests/BashTaskEventReducerTests \
  -only-testing:agentGuiTests/BashToolSchemaTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests \
  -only-testing:agentGuiTests/AgentMessageFlowPresentationTests
```

Expected: PASS.

**Step 2: Run a build smoke test**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: BUILD SUCCESS.

**Step 3: Update docs to match shipped behavior**

Document:

- supported bash schema fields
- compatibility path for legacy flags
- known limitations of the non-PTY transport
- supported prompt categories

**Step 4: Manual smoke test checklist**

Verify all of these in the running app:

- `npm run dev` becomes a managed background task
- `npx create-*` enters interactive handling
- safe yes/no prompt can auto-continue
- password prompt escalates to user question
- background task can be observed and stopped from the same conversation

**Step 5: Commit**

```bash
git add README.md docs/spec/2026-03-10-bash-tool-redesign-requirements.md
git commit -m "docs: finalize managed bash tool redesign"
```
