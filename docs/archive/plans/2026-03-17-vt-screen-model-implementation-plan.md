# VT Screen Model Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current transcript-based `TerminalSurfaceExtractor` path with a real VT parser, screen buffer, semantic surface projector, and visible terminal screen UI for attached bash tasks.

**Architecture:** Build the replacement in vertical slices. Start by introducing a minimal VT parser and persistent screen model inside `TerminalTaskRuntime`, then add a semantic projector that feeds the existing planner contract, then delete the old extractor path, then replace execute-detail metadata cards with a `TerminalScreenView` as the primary bash task detail UI.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, Foundation, Darwin PTY runtime, existing `TerminalTaskRuntime`, `AgentLoopToolExecutionCoordinatorBuilder`, `ToolCall`, and terminal task UI.

---

- 我正在使用 writing-plans skill 来创建这份 implementation plan。

## 0. Design constraints

- Strict TDD. Every behavior starts with a failing test.
- Do not keep or extend `TerminalSurfaceExtractor` as a compatibility wrapper.
- Unknown TUI support must come from `VT parser -> screen buffer -> semantic projector`, not transcript repair.
- Attached interactive bash detail UI must prioritize a visible terminal screen, not metadata cards.
- Known scaffolders can still have command adapters, but unknown TUI handling must not depend on them.
- Keep manual stop and takeover controls available throughout the migration.
- Prefer deleting obsolete code as soon as the replacement path is green.

## 1. Current codebase anchors

These are the main code paths the implementation will build on or replace:

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/PtyProcessController.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalInteractionPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceExtractorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalInteractionPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-17-vt-screen-model-design.md`

## 2. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalVTParser.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenModel.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalScreenView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalVTParserTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenViewTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalInteractionPlanner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalInteractionPlannerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

### Deleted files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceExtractor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceExtractorTests.swift`

## 3. Delivery strategy

Deliver this in five milestones:

1. VT parser foundation.
2. Persistent screen model inside runtime.
3. Semantic projector and planner integration.
4. UI replacement with `TerminalScreenView`.
5. Deletion of old extractor path and cleanup.

Do not start by deleting the extractor file. First make the replacement path pass focused tests, then remove the obsolete path in one dedicated cleanup task.

## 4. Task breakdown

### Task 1: Add VT parser primitives

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalVTParser.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalVTParserTests.swift`

**Step 1: Write the failing test**

Add parser tests that lock the first supported VT subset:

- printable UTF-8 text
- `CR`, `LF`, `BS`, `TAB`
- `CSI H`, `CSI A/B/C/D`
- `CSI J`, `CSI K`
- `CSI m` SGR
- alternate screen enable/disable for `?1049h` / `?1049l`

Example:

```swift
@Test func parserEmitsAlternateScreenEnterAndExit() throws {
    let events = TerminalVTParser().parse("\u{001B}[?1049hhello\u{001B}[?1049l")

    #expect(events.contains(.enterAlternateScreen))
    #expect(events.contains(.print("hello")))
    #expect(events.contains(.exitAlternateScreen))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalVTParserTests
```

Expected: FAIL because `TerminalVTParser` and VT parser events do not exist.

**Step 3: Write minimal implementation**

Implement a parser that produces a small event stream sufficient for the supported subset. Do not implement the full xterm spec.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalVTParser.swift agentGuiTests/TerminalVTParserTests.swift
git commit -m "feat: add minimal vt parser"
```

### Task 2: Add persistent terminal screen model

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalScreenModel.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/TerminalSurfaceModels.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenModelTests.swift`

**Step 1: Write the failing test**

Add tests for:

- primary vs alternate buffer switching
- cursor movement
- line erase / display erase
- wide-character continuation cell handling at minimum shape level
- exporting a stable `TerminalScreenSnapshot`

Example:

```swift
@Test func screenModelWritesPrintedTextAtCursorPosition() {
    var screen = TerminalScreenModel(width: 20, height: 8)
    screen.apply(.print("hello"))

    let snapshot = screen.snapshot()
    #expect(snapshot.plainTextLines.first == "hello")
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalScreenModelTests
```

Expected: FAIL because `TerminalScreenModel` does not exist.

**Step 3: Write minimal implementation**

Implement:

- screen cell model
- screen buffer model
- cursor state
- snapshot export
- application of the parser events introduced in Task 1

Keep it self-contained and independent from planner logic.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalScreenModel.swift agentGui/Models/TerminalSurfaceModels.swift agentGuiTests/TerminalScreenModelTests.swift
git commit -m "feat: add terminal screen model"
```

### Task 3: Store screen sessions in terminal runtime

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalTaskRuntimeTests.swift`

**Step 1: Write the failing test**

Add runtime tests proving that:

- each attached/detached task owns a screen model
- incoming PTY output is applied incrementally to the screen model
- runtime can export a `TerminalScreenSnapshot` without rebuilding from transcript
- cleanup removes the screen session

Example:

```swift
@Test func runtimeMaintainsScreenSnapshotFromStreamingOutput() async throws {
    let runtime = await TerminalTaskRuntime.makeForTests()
    _ = try await runtime.startDetached(command: "printf 'hello'", taskId: "screen-task")

    let snapshot = try await runtime.screenSnapshot(taskId: "screen-task")
    #expect(snapshot.plainTextLines.joined().contains("hello"))
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests
```

Expected: FAIL because runtime has no screen-session API.

**Step 3: Write minimal implementation**

Add task-bound screen sessions in `TerminalTaskRuntime` and feed them from PTY output. Do not involve planner or UI yet.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalTaskRuntime.swift agentGuiTests/TerminalTaskRuntimeTests.swift
git commit -m "feat: persist vt screen sessions in terminal runtime"
```

### Task 4: Add semantic surface projector

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceProjector.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceProjectorTests.swift`

**Step 1: Write the failing test**

Add projector tests for:

- confirm dialog surface
- radio surface
- multi-select surface
- text-input surface
- non-interactive screen returns no semantic surface

Use artificial `TerminalScreenSnapshot` fixtures instead of transcript strings.

Example:

```swift
@Test func projectorBuildsConfirmSurfaceFromFocusedRadioScreen() {
    let snapshot = TerminalScreenSnapshot.fixtureConfirm(
        prompt: "Target directory \"vue3-demo\" is not empty. Remove existing files and continue?",
        options: ["Yes", "No"],
        focusedIndex: 1
    )

    let surface = TerminalSurfaceProjector().project(snapshot)

    #expect(surface?.interactionType == .confirm)
    #expect(surface?.options.count == 2)
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests
```

Expected: FAIL because `TerminalSurfaceProjector` does not exist.

**Step 3: Write minimal implementation**

Implement projector logic that consumes screen snapshots and emits semantic interaction surfaces. Do not read transcript text in this layer.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/Terminal/TerminalSurfaceProjector.swift agentGuiTests/TerminalSurfaceProjectorTests.swift
git commit -m "feat: add semantic terminal surface projector"
```

### Task 5: Switch planner orchestration to screen snapshots

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalInteractionPlanner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalInteractionPlannerTests.swift`

**Step 1: Write the failing test**

Add focused orchestration tests proving that:

- planner receives projected semantic surface built from `TerminalScreenSnapshot`
- prompt fallback still runs first for simple yes/no questions
- unknown TUI enters planning with a stable surface instead of transcript heuristics

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalInteractionPlannerTests
```

Expected: FAIL because planner and builder still depend on transcript extraction.

**Step 3: Write minimal implementation**

Update the builder to:

- fetch `TerminalScreenSnapshot` from runtime
- run prompt fallback on projector-produced prompt text or stable plain-text snapshot
- run `TerminalSurfaceProjector`
- hand semantic surface to planner

Do not leave any main-path call to `TerminalSurfaceExtractor`.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift agentGui/Services/Terminal/TerminalInteractionPlanner.swift agentGuiTests/TerminalInteractionPlannerTests.swift
git commit -m "refactor: drive terminal planning from screen snapshots"
```

### Task 6: Replace execute detail UI with TerminalScreenView

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/TerminalScreenView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallDetailContentView.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Views/ToolCallBubbleView.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalScreenViewTests.swift`
- Test: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/BashToolCallPresentationTests.swift`

**Step 1: Write the failing test**

Add tests that lock the new UI contract:

- attached interactive execute detail shows a terminal screen view as the main area
- takeover controls sit adjacent to the screen view
- planner/approval metadata lives in secondary diagnostic sections
- detached or non-interactive execute detail can still use compact summary fallback

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalScreenViewTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Expected: FAIL because there is no `TerminalScreenView` and execute detail is still metadata-first.

**Step 3: Write minimal implementation**

Implement `TerminalScreenView` and update execute detail composition so the visible terminal screen is the primary detail experience.

**Step 4: Run test to verify it passes**

Run the same command and expect PASS.

**Step 5: Commit**

```bash
git add agentGui/Views/TerminalScreenView.swift agentGui/Views/ToolCallDetailContentView.swift agentGui/Views/ToolCallBubbleView.swift agentGuiTests/TerminalScreenViewTests.swift agentGuiTests/BashToolCallPresentationTests.swift
git commit -m "feat: show vt terminal screen in bash task detail"
```

### Task 7: Delete the old extractor path

**Files:**
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalSurfaceExtractor.swift`
- Delete: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/TerminalSurfaceExtractorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/Terminal/TerminalTaskRuntime.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinatorBuilder.swift`

**Step 1: Write the failing test or build assertion**

Before deletion, add or run a build assertion proving the replacement path is complete and no references remain.

Use:

```bash
rg "TerminalSurfaceExtractor" /Volumes/T7/文稿/Projects/agentGui
```

Expected before cleanup: references still exist.

**Step 2: Remove all references and delete files**

Delete the extractor implementation and its tests. Remove any leftover imports, logging, or helper calls.

**Step 3: Run search to verify nothing remains**

Run:

```bash
rg "TerminalSurfaceExtractor" /Volumes/T7/文稿/Projects/agentGui
```

Expected: no matches.

**Step 4: Run focused tests and build**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalVTParserTests \
  -only-testing:agentGuiTests/TerminalScreenModelTests \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests \
  -only-testing:agentGuiTests/TerminalInteractionPlannerTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests

xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
```

Expected: PASS.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove transcript surface extractor"
```

### Task 8: Update docs to match shipped architecture

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-16-bash-interactive-orchestration.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/bash tool.md`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/plans/2026-03-17-vt-screen-model-design.md`

**Step 1: Write the failing doc checklist**

Add a checklist in the implementation PR or task notes requiring the docs to state:

- `TerminalSurfaceExtractor` was removed
- unknown TUI now uses VT parser + screen model + projector
- bash detail UI now shows a visible terminal screen
- metadata is secondary diagnostic information

**Step 2: Update docs**

Write only the final architecture, not transition notes.

**Step 3: Manual verification**

Verify the docs match the code and there is no mention of keeping extractor compatibility.

**Step 4: Commit**

```bash
git add docs/technical-spec/2026-03-16-bash-interactive-orchestration.md docs/bash\ tool.md docs/plans/2026-03-17-vt-screen-model-design.md
git commit -m "docs: describe vt screen model architecture"
```

## 5. Validation matrix

Run these focused suites during implementation:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -parallel-testing-enabled NO \
  -only-testing:agentGuiTests/TerminalVTParserTests \
  -only-testing:agentGuiTests/TerminalScreenModelTests \
  -only-testing:agentGuiTests/TerminalSurfaceProjectorTests \
  -only-testing:agentGuiTests/TerminalTaskRuntimeTests \
  -only-testing:agentGuiTests/TerminalInteractionPlannerTests \
  -only-testing:agentGuiTests/TerminalScreenViewTests \
  -only-testing:agentGuiTests/BashToolCallPresentationTests
```

Run broader verification after deleting the old path:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' build
./scripts/run_quality_smoke.sh
```

## 6. Acceptance criteria

The implementation is complete when all of these are true:

1. `TerminalSurfaceExtractor` no longer exists in the workspace.
2. `TerminalTaskRuntime` owns persistent per-task screen sessions.
3. Unknown TUI interaction surfaces are produced from `TerminalScreenSnapshot`, not transcript lines.
4. Planner input is based on screen state and semantic projection.
5. Attached interactive bash detail shows a visible terminal screen as the primary UI.
6. Metadata is secondary diagnostic information, not the main execute-detail presentation.
7. Focused VT parser/screen model/projector tests pass.
8. Build passes after the extractor path is removed.

## 7. Explicit non-goals

- Full xterm feature completeness in the first iteration.
- Mouse protocol support.
- Replacing known command adapters with TUI understanding.
- Perfect styling parity with a real terminal emulator on day one.
- Supporting every third-party TUI framework in the first milestone.

Plan complete and saved to `docs/plans/2026-03-17-vt-screen-model-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?