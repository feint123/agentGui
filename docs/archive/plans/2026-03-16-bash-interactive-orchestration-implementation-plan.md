# Bash Interactive Orchestration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Evolve the Bash tool from prompt-string heuristics into a managed interactive terminal orchestration system that can understand complex PTY screens, plan safe key actions, escalate uncertainty to the user, and keep strong manual-stop / takeover controls.

**Architecture:** Build this in layers instead of trying to make `BashPromptAnalyzer` smarter forever. First add terminal-surface extraction and interaction action models on top of the existing PTY runtime, then add shell-integration semantics and an LLM-driven interaction planner, then wire the planner into the agent loop with explicit approval and takeover UX. Keep `BashPromptAnalyzer` as a low-cost fallback policy engine for simple prompts only.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftUI, Foundation, Darwin PTY APIs, existing `TerminalTaskRuntime`, `ClaudeService`, `ToolCall`, `AgentLoopToolExecutionCoordinatorBuilder`, `AskUserQuestion`, terminal task UI.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. Design constraints

- Strict TDD: every new behavior starts with a failing test.
- Do not keep growing `BashPromptAnalyzer` into a giant rules engine.
- Preserve the current PTY runtime and task-based routing as the transport foundation.
- Keep manual stop available at every stage.
- Complex interactive flows must degrade cleanly to user approval or user takeover.
- Planner output must be structured, not freeform text.
- First-class key actions are required; raw `send_input(String)` is not enough for TUIs.
- Prefer small reversible milestones over a single rewrite.

## 1. Current codebase anchors

These are the main code paths the implementation will build on:

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

## 2. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalKeyEncoder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalInteractionPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalShellIntegrationParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalKeyEncoderTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalInteractionPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalShellIntegrationParserTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

## 3. Delivery strategy

Deliver this in four milestones:

1. Surface foundation: model terminal screens and key actions.
2. Semantic enrichment: parse shell-integration events and improve task snapshots.
3. Planner scaffolding: add a structured interaction planner with tests and safe fallback.
4. Agent-loop orchestration and UX: wire planner decisions into execution, approval, and takeover flows.

Do not start with the planner. Without a surface model and action model, planner output will be too vague to execute safely.

## 4. Task breakdown

### Task 1: Add terminal surface and interaction action models

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalTaskModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskModelsTests.swift`

**Step 1: Write the failing test**

Add tests that lock these new domain types:

- `TerminalSurfaceSnapshot`
- `TerminalVisibleOption`
- `TerminalSelectionMode`
- `TerminalInteractionAction`
- `TerminalInteractionPlan`

Example test shape:

```swift
@Test func terminalInteractionActionSupportsKeyAndTextInput() {
    let enter = TerminalInteractionAction.key(.enter)
    let text = TerminalInteractionAction.text("vue3-demo")

    #expect(enter.isKeyboardAction)
    #expect(text.isKeyboardAction == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalTaskModelsTests
```

Expected: FAIL because the new terminal surface and interaction types do not exist.

**Step 3: Write minimal implementation**

Create `TerminalSurfaceModels.swift` with:

- `TerminalSurfaceSnapshot`
- `TerminalVisibleOption`
- `TerminalSelectionMode`
- `TerminalInteractionAction`
- `TerminalInteractionPlan`
- `TerminalInteractionObservation`

Only include fields that the next tasks need. Do not add planner metadata that is not yet consumed.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/TerminalSurfaceModels.swift agentGui/Models/TerminalTaskModels.swift agentGuiTests/TerminalTaskModelsTests.swift
git commit -m "feat: add terminal surface and interaction models"
```

### Task 2: Add a key encoder so actions can be executed safely

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalKeyEncoder.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalKeyEncoderTests.swift`

**Step 1: Write the failing test**

Add tests for:

- `enter` -> newline
- `space` -> space character
- arrow keys -> ANSI escape sequences
- `interrupt` remains a signal, not text

Example:

```swift
@Test func keyEncoderMapsArrowKeysToAnsiSequences() {
    #expect(TerminalKeyEncoder().encode(.up) == "\u{1B}[A")
    #expect(TerminalKeyEncoder().encode(.down) == "\u{1B}[B")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalKeyEncoderTests
```

Expected: FAIL because the encoder does not exist.

**Step 3: Write minimal implementation**

Implement:

- `TerminalKey` enum
- `TerminalKeyEncoder.encode(_:)`

Only support the keys that the plan currently needs:

- `enter`
- `space`
- `tab`
- `up`
- `down`
- `left`
- `right`

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalKeyEncoder.swift agentGuiTests/TerminalKeyEncoderTests.swift
git commit -m "feat: add terminal key encoder"
```

### Task 3: Build the first terminal surface extractor from PTY output

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceExtractor.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceExtractorTests.swift`

**Step 1: Write the failing test**

Add tests that lock the first extractor milestone:

- strips ANSI color/control sequences into plain text
- detects alternate screen usage
- extracts visible checkbox-style options
- identifies a focused option candidate from prompt symbols like `◆`, `◇`, `❯`, `>`

Use real samples from `create-vue` style output.

Example:

```swift
@Test func extractorBuildsMultiSelectSurfaceFromCreateVueScreen() {
    let screen = """
    ◆  请选择要包含的功能： (↑/↓ 切换，空格选择，a 全选，回车确认)
    │  ◻ JSX 支持
    │  ◻ Router（单页面应用开发）
    │  ◻ Pinia（状态管理）
    │  ◻ Vitest（单元测试）
    """

    let snapshot = TerminalSurfaceExtractor().extract(from: screen)

    #expect(snapshot.selectionMode == .multiSelect)
    #expect(snapshot.visibleOptions.count == 4)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalSurfaceExtractorTests
```

Expected: FAIL because the extractor does not exist.

**Step 3: Write minimal implementation**

Implement `TerminalSurfaceExtractor.extract(from:)` that:

- normalizes line endings
- removes a first pass of ANSI escape sequences
- detects visible options by common bullet patterns
- sets `selectionMode` to `.singleSelect`, `.multiSelect`, or `.unknown`
- records `plainTextFrame` and `rawANSISnippet`

Do not implement a full VT parser yet.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalSurfaceExtractor.swift agentGuiTests/TerminalSurfaceExtractorTests.swift
git commit -m "feat: add terminal surface extractor"
```

### Task 4: Parse shell integration events and enrich runtime snapshots

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalShellIntegrationParser.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalShellIntegrationParserTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`

**Step 1: Write the failing test**

Add parser tests for:

- `OSC 633 ; A/B/C/D`
- cwd property events
- explicit command line events

Add runtime tests that confirm:

- cwd can be updated from shell integration
- command completion can capture exit code when shell events are present

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalShellIntegrationParserTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests
```

Expected: FAIL because shell integration parsing is not implemented.

**Step 3: Write minimal implementation**

Implement a parser that can recognize a small supported subset:

- prompt start/end
- pre-exec
- command complete + exit code
- cwd property
- explicit command line

Update `TerminalTaskRuntime` to store the latest semantic properties on the task snapshot.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalShellIntegrationParser.swift agentGui/Services/Terminal/PtyProcessController.swift agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGuiTests/TerminalShellIntegrationParserTests.swift agentGuiTests/TerminalTaskRuntimeTests.swift
git commit -m "feat: parse shell integration events for terminal tasks"
```

### Task 5: Re-scope `BashPromptAnalyzer` to low-cost fallback only

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/BashPromptAnalyzer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashPromptAnalyzerTests.swift`

**Step 1: Write the failing test**

Add tests that prove analyzer behavior is intentionally narrow:

- yes/no and install prompts still work
- password and destructive confirmation still escalate
- `create-vue` multi-select screens return a non-terminal fallback classification such as `.unknown` or no decision

The point is to prevent future feature creep back into analyzer regexes.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BashPromptAnalyzerTests
```

Expected: FAIL because the analyzer still tries to stretch beyond fallback duties.

**Step 3: Write minimal implementation**

Keep only:

- yes/no
- package-manager install confirm
- press-enter
- password
- destructive confirmation

Do not add menu parsing or multi-select inference here.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/BashPromptAnalyzer.swift agentGuiTests/BashPromptAnalyzerTests.swift
git commit -m "refactor: narrow bash prompt analyzer to fallback policy"
```

### Task 6: Add a structured interaction planner facade

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalInteractionPlanner.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalInteractionPlannerTests.swift`

**Step 1: Write the failing test**

Add tests for a planner facade that takes:

- user goal
- current command
- `TerminalSurfaceSnapshot`
- recent output

And returns a `TerminalInteractionPlan`.

For the first milestone, do not call a real LLM. Use a deterministic stub planner and lock the contract.

Example:

```swift
@Test func plannerProducesFeatureSelectionActionsForCreateVueSurface() async throws {
    let planner = TerminalInteractionPlanner.stubForTests()
    let surface = TerminalSurfaceSnapshot.fixtureMultiSelect(options: ["JSX 支持", "Router（单页面应用开发）", "Pinia（状态管理）", "Vitest（单元测试）"])

    let plan = try await planner.plan(
        goal: "Create a Vue app with TypeScript, JSX, Router, Pinia, Vitest",
        command: "npm create vue@latest vue3-demo",
        surface: surface,
        recentOutput: surface.plainTextFrame
    )

    #expect(plan.nextActions.isEmpty == false)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalInteractionPlannerTests
```

Expected: FAIL because the planner facade does not exist.

**Step 3: Write minimal implementation**

Implement:

- planner protocol
- stub / fixture planner for tests
- request / response contract
- confidence and approval fields

No Anthropic integration yet. This task is only about stabilizing the shape.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalInteractionPlanner.swift agentGuiTests/TerminalInteractionPlannerTests.swift
git commit -m "feat: add terminal interaction planner contract"
```

### Task 7: Integrate planner-driven interaction into the agent loop

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+BashTool.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Write the failing test**

Add integration tests for:

- planner receives a multi-select surface and returns actions
- runtime executes key actions in order
- low-confidence plans escalate to user approval instead of auto-executing

Use a fake planner first so the host-side orchestration is proven before adding a real LLM-backed planner.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL because the agent loop still only knows prompt-detection + send_input.

**Step 3: Write minimal implementation**

Update the observation loop to:

- build `TerminalSurfaceSnapshot`
- decide whether to use fallback analyzer or planner
- apply `TerminalInteractionAction`s through `sendInput` and key encoding
- write planner decisions into terminal task events
- request user approval when `requiresUserConfirmation == true`

Do not yet implement user takeover.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGui/Services/ClaudeService+BashTool.swift agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: orchestrate planner-driven terminal interaction"
```

### Task 8: Add approval, takeover, and richer UI state

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ToolCall.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/ViewModels/ToolCallRowPresentation.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

**Step 1: Write the failing test**

Add tests that lock these UX states:

- planner is thinking
- approval requested
- user takeover active
- manual stop button remains visible during any non-terminal interactive state

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: FAIL because those richer terminal interaction states are not projected into presentation yet.

**Step 3: Write minimal implementation**

Extend `ToolCall` terminal metadata to capture:

- current interaction phase
- last planner summary
- whether approval is pending
- whether user takeover is active

Update bubble/detail presentation to show this cleanly. Keep the stop icon button compact and always available while the task is not terminal.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/ToolCall.swift agentGui/Views/ToolCallBubbleView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/ViewModels/ToolCallRowPresentation.swift agentGuiTests/BashToolCallPresentationTests.swift
git commit -m "feat: present terminal planner and takeover states in ui"
```

### Task 9: Add end-to-end fixtures for complex interactive commands

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TestSupport/TerminalInteractiveFixtures.swift`

**Step 1: Write the failing test**

Create reusable integration fixtures for:

- `npm create vue@latest`
- `create-next-app`
- password prompt
- destructive overwrite prompt
- simple REPL prompt

Each fixture should replay screen transitions as PTY output snapshots.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: FAIL because the fixture coverage and planner orchestration are incomplete.

**Step 3: Write minimal implementation**

Add test support helpers only. Keep these fixtures deterministic and small.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/TestSupport/TerminalInteractiveFixtures.swift
git commit -m "test: add interactive terminal fixtures"
```

### Task 10: Add documentation and operational guardrails

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-16-bash-interactive-orchestration.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/bash tool.md`

**Step 1: Write the failing doc checklist**

Create a checklist in the commit or PR description that requires:

- documented planner contract
- documented approval / takeover behavior
- documented fallback analyzer scope
- documented shell-integration dependency

**Step 2: Update docs**

Document the final runtime behavior, not intermediate experiments.

**Step 3: Manual verification**

Verify the docs match the shipped behavior using the test suite and one real interactive command.

**Step 4: Commit**

```bash
git add docs/technical-spec/2026-03-16-bash-interactive-orchestration.md docs/bash tool.md
git commit -m "docs: document interactive terminal orchestration"
```

## 5. Validation matrix

Run these focused suites during implementation:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/TerminalTaskModelsTests \
  -only-testing:agentGuiTests/TerminalKeyEncoderTests \
  -only-testing:agentGuiTests/TerminalSurfaceExtractorTests \
  -only-testing:agentGuiTests/TerminalShellIntegrationParserTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests \
  -only-testing:agentGuiTests/BashPromptAnalyzerTests \
  -only-testing:agentGuiTests/TerminalInteractionPlannerTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Run the broader smoke after major milestones:

```bash
./scripts/run_quality_smoke.sh
```

## 6. Acceptance criteria

The implementation is complete when all of these are true:

1. `BashPromptAnalyzer` only handles simple fallback prompts.
2. The system can build a `TerminalSurfaceSnapshot` from `create-vue`-style screens.
3. Interaction actions are structured and executable as key/text/signal operations.
4. Planner output is structured and recorded in terminal task events.
5. Low-risk, high-confidence interactions can progress automatically.
6. Medium- or low-confidence interactions request approval or user takeover instead of guessing.
7. Manual stop remains available from the UI throughout the task lifecycle.
8. Integration tests cover at least one real multi-step installer flow.

## 7. Explicit non-goals for this plan

- Building a full VT100 emulator in one pass.
- Supporting every TUI application.
- Replacing shell integration for shells that do not expose it.
- Shipping a fully autonomous planner before surface extraction is stable.
- Eliminating all heuristics from the system. Heuristics remain as a fallback layer.

Plan complete and saved to `docs/plans/2026-03-16-bash-interactive-orchestration-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?