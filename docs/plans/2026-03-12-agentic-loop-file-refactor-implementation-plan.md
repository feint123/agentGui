# Agentic Loop File Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor `ClaudeService+AgenticLoop.swift` so the file becomes a thin orchestration layer instead of a 1200-line god file, while preserving the current agent loop behavior.

**Architecture:** Keep the existing explicit state machine (`AgentLoopContext` / `AgentLoopPhase`) and hook pipeline (`AgentLoopHookDispatcher` + built-in hooks). Add a small set of focused collaborators around them: a round stream assembler, a tool execution coordinator, a memory bootstrap composer, and a phase outcome applier. The main loop remains the orchestration entry point, but most branch-heavy logic moves into typed components with characterization tests.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, existing `ClaudeService` extensions, existing agent loop hook system.

---

## 1. Review summary

### Main findings

- `runCoreAgentLoop(...)` currently mixes at least six responsibilities: run setup, hook wiring, stream parsing, state-machine progression, tool execution, and memory/reflection persistence.
- The file already contains good primitives worth keeping: an explicit phase model, a hook dispatcher, hook factory extraction, and isolated helper extensions for reflection / compression / tool call records.
- The main maintenance risk is not the loop itself, but the amount of inline branching inside one method. The highest-risk block is the `.awaitingToolResults` branch because it combines tool routing, bash live polling, persistence, failure classification, and result injection.
- The current architecture is already halfway to a better design. The right move is not a full rewrite, but to complete the separation into orchestration + collaborators.

### Recommended patterns

- **Coordinator / Orchestrator:** `runCoreAgentLoop(...)` should own run-level sequencing only.
- **State Machine:** keep `AgentLoopContext` and `AgentLoopPhase` as the single source of truth for loop progression.
- **Strategy:** move special tool handling (`run_subagent`, `start_workflow`, default tools, bash polling) behind a dedicated coordinator with typed strategies.
- **Assembler:** move streaming event accumulation (`text_delta`, `thinking_delta`, partial tool JSON, stop reason) into a dedicated round assembler.
- **Facade:** expose a single bootstrap composer for unified memory / task memory / story memory prompt injection.

## 2. Scope and constraints

- This is a structural refactor first. No product behavior changes unless a test exposes an existing bug.
- Preserve the public entry points used by main agent, subagent, and workflow runner:
  - `runAgenticLoop(...)`
  - `runCoreAgentLoop(...)`
- Preserve the existing hook stages and `AgentLoopBuiltInHookFactory` contract.
- Do not merge this refactor with unrelated cleanup in other service files.
- Prefer new focused files over adding more nested local functions.

## 3. Target file layout

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundStreamAssembler.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopPhaseOutcomeApplier.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundStreamAssemblerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopFailureClassificationHookTests.swift`

## 4. Task breakdown

### Task 1: Lock current behavior with characterization tests

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundStreamAssemblerTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`

**Step 1: Write the failing tests**

Cover these seams before extracting code:

- stream events with `text_delta`, `thinking_delta`, `signature_delta`, `partial_json`, and stop reason are assembled into one round snapshot correctly
- `tool_use` with no parsed tools still fails the loop
- finalization guard retry restores `accumulatedText` to the pre-round value and appends the correction prompt
- reflection only starts when `pendingFailureTrigger` is present and retry limit is below 3

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerTests \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: FAIL because the extracted collaborators do not exist yet.

**Step 3: Commit**

```bash
git add agentGuiTests/AgentLoopRoundStreamAssemblerTests.swift agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "test: characterize agent loop extraction seams"
```

### Task 2: Extract round stream assembly

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopRoundStreamAssembler.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopRoundStreamAssemblerTests.swift`

**Step 1: Write the failing implementation skeleton**

Create a type that owns per-round streaming accumulation.

Suggested shape:

```swift
struct AgentLoopRoundStreamSnapshot {
    var text: String
    var thinkingContent: String
    var thinkingSignature: String?
    var pendingTools: [PendingTool]
    var stopReason: String?
}

struct AgentLoopRoundStreamAssembler {
    mutating func consume(_ event: MessageStreamResponse) -> AgentLoopRoundStreamSnapshotDelta
    var snapshot: AgentLoopRoundStreamSnapshot { get }
}
```

`PendingThinking`, `PendingToolUse`, `currentBlockIndex`, and stop-reason parsing move here.

**Step 2: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerTests
```

Expected: PASS.

**Step 3: Refactor loop usage**

Replace the inline `for try await event in stream` bookkeeping variables with the assembler, while keeping hook emission in `runCoreAgentLoop(...)`.

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopRoundStreamAssembler.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopRoundStreamAssemblerTests.swift
git commit -m "refactor: extract agent loop round stream assembler"
```

### Task 3: Extract memory bootstrap composition

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopMemoryBootstrapComposer.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift`

**Step 1: Write the failing tests**

Cover:

- unified memory bootstrap wins when available
- task memory fallback produces the current insertion order and metadata
- story memory bootstrap appends after task/unified memory using the current insertion rules
- empty sources produce no patch

**Step 2: Implement a facade**

Move the current closure-heavy bootstrap logic into a dedicated composer with a single entry point, for example:

```swift
struct AgentLoopMemoryBootstrapComposer {
    func makePatch(...) async throws -> AgentLoopMessagePatch?
}
```

Keep `buildUnifiedMemoryBootstrap(...)` and `buildStoryMemoryBootstrap(...)` callable from the composer rather than duplicating their internals.

**Step 3: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests
```

Expected: PASS.

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopMemoryBootstrapComposer.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopMemoryBootstrapComposerTests.swift
git commit -m "refactor: extract agent loop memory bootstrap composer"
```

### Task 4: Extract tool execution coordinator

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

**Step 1: Write the failing tests**

Cover:

- `run_subagent` routes to subagent execution and preserves audit metadata
- `start_workflow` routes to workflow execution
- bash foreground execution starts live polling and final registry state update
- generic tool execution still uses `executeTool(...)`
- interceptor result wins over built-in routing

**Step 2: Implement the coordinator with strategy-style routing**

Use one coordinator entry point, for example:

```swift
struct AgentLoopToolExecutionCoordinator {
    func execute(pendingTool: PendingTool, context: ExecutionContext) async -> ExecutedToolResult
}
```

Keep the strategies small and explicit. Do not introduce protocol-heavy abstractions unless the tests force them.

**Step 3: Replace the `.awaitingToolResults` inline branch**

`runCoreAgentLoop(...)` should only:

- ask hooks for pre-execution state
- call the coordinator
- emit post-execution hooks
- append assistant/tool result messages

It should no longer manage bash polling details inline.

**Step 4: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopFailureClassificationHookTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopToolExecutionCoordinator.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift agentGuiTests/AgentLoopFailureClassificationHookTests.swift
git commit -m "refactor: extract agent loop tool execution coordinator"
```

### Task 5: Extract phase outcome application

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopPhaseOutcomeApplier.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`

**Step 1: Write the failing tests**

Cover:

- continuation on `max_tokens`
- resume on `pause_turn`
- finalization allow / retry / fail behavior
- reflection transition rules
- max-rounds terminal result formatting remains unchanged

**Step 2: Implement a focused outcome applier**

Move the `switch loopCtx.phase` branch body into a dedicated helper that returns message appends, projection resets, and next-state updates as typed output.

The loop should still own the outer `while` and hook dispatch boundaries.

**Step 3: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests
```

Expected: PASS.

**Step 4: Commit**

```bash
git add agentGui/Services/AgentLoopPhaseOutcomeApplier.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift
git commit -m "refactor: extract agent loop phase outcome applier"
```

### Task 6: Slim the main file and run regression validation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`

**Step 1: Final cleanup**

After all collaborators exist, reduce `ClaudeService+AgenticLoop.swift` to:

- public entry points
- run setup and dependency wiring
- hook dispatch helpers
- the main loop orchestration
- small helper methods that are still clearly service-owned (`isThinkingCapable(...)`, `recordReflectionFailure(...)`)

Move any helper that is no longer specific to `ClaudeService` into the new focused files.

**Step 2: Run focused regression tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopBuiltInHookFactoryTests \
  -only-testing:agentGuiTests/AgentLoopHookDispatcherTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/AgentLoopFailureClassificationHookTests \
  -only-testing:agentGuiTests/AgentLoopRoundStreamAssemblerTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapComposerTests \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests
```

Expected: PASS.

**Step 3: Run repository smoke validation**

Run the existing workspace task:

```text
Quality Smoke
```

Expected: PASS, or only pre-existing unrelated failures.

**Step 4: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopBusinessObservabilityTests.swift
git commit -m "refactor: slim agent loop orchestration file"
```

## 5. Definition of done

- `ClaudeService+AgenticLoop.swift` is reduced to orchestration responsibilities and is materially smaller than the current 1231 lines.
- Stream parsing, tool execution, memory bootstrap composition, and phase outcome application each live in separate focused files.
- Main agent, subagent, and workflow runner still compile against the same public loop API.
- Hook-driven observability and failure classification behavior remains intact.
- Focused agent loop tests pass, followed by the workspace smoke task.

## 6. Non-goals

- No redesign of the hook protocol or hook stage taxonomy.
- No rewrite of `ClaudeService` into a brand-new object graph.
- No behavioral changes to memory semantics, workflow contracts, or bash permission policy in this refactor.
- No UI changes.

## 7. Execution note

This plan assumes the existing hook-related plans from 2026-03-12 remain the foundation. Execute those first if the workspace does not yet contain the extracted hook factory / hook system pieces referenced here.

Plan complete and saved to `docs/plans/2026-03-12-agentic-loop-file-refactor-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?