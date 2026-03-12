# Agent Loop Hook Factory Extraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract the built-in hook assembly from `runCoreAgentLoop(...)` into an explicit per-run hook builder so the loop keeps the same behavior but sheds hidden closure capture and local factory complexity.

**Architecture:** Keep `runCoreAgentLoop(...)` as the execution engine, but replace the nested `makeAgentLoopHooks()` function with a dedicated builder that receives a small, explicit runtime dependency bundle plus a mutable per-run state holder. Preserve the current hook contract and built-in hook set; this refactor is structural, not behavioral.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, existing `AgentLoopHook`, `AgentLoopHookDispatcher`, and built-in agent loop hooks.

---

## 1. Scope and constraints

- This is a pure refactor. No new hook stages, no new business behavior, no loop state-machine redesign.
- `runCoreAgentLoop(...)` must continue to own loop progression, streaming, tool execution, and hook dispatch boundaries.
- The extracted builder must still support current per-run mutable state:
  - `lastRound`
  - `memoryRuntimeProfiles`
  - `memoryRuntimeLayers`
  - `memoryRuntimeWarnings`
  - `memoryRuntimeSnapshotID`
- Avoid over-engineering. A small builder + state holder is sufficient; do not introduce a plugin system or generalized DI container.

## 2. Target design

### 2.1 New pieces

- Add a dedicated builder file for built-in hook assembly.
- Add a small state holder type for values currently captured implicitly by nested closures.
- Add a small immutable dependency bundle for services and per-call inputs.

### 2.2 Resulting ownership

- `runCoreAgentLoop(...)`
  - creates run-local state holder
  - creates immutable builder dependency bundle
  - requests built-in hooks from builder
  - creates `AgentLoopHookDispatcher`
- builder
  - assembles `StreamProjectionHook`
  - assembles `MemoryBootstrapHook`
  - assembles `ToolAuditHook`
  - assembles `FailureClassificationHook`
  - assembles `ReflectionHandlingHook`
  - assembles `FinalizationGuardHook`
  - assembles `BusinessObservabilityHook`

### 2.3 Recommended extraction boundary

- Keep `dispatchHooks(...)`, `emitHook(...)`, `pendingToolID(...)`, and `roundForToolContext(...)` inside `runCoreAgentLoop(...)` for now.
- Extract only the built-in hook assembly first. Do not combine this with a larger loop split.

## 3. Files to touch

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopReflectionAndGuardHookTests.swift`

---

## 4. Task breakdown

### Task 1: Lock the extraction seam with characterization tests

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolAuditHookTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopReflectionAndGuardHookTests.swift`

**Step 1: Write the failing tests**

Add tests that lock the builder contract instead of the current nesting detail.

Required coverage:

- built-in hook list contains the current hook IDs in stable order
- `MemoryBootstrapHook` can mutate a shared run state holder with memory runtime metadata
- `ToolAuditHook` reads memory runtime metadata from the shared state holder
- `ReflectionHandlingHook` can read and update a shared `lastRound` reference via the shared state holder

Suggested test sketch:

```swift
@Test func builtInHookFactoryCreatesExpectedHookSetInOrder() async throws {
    let factory = AgentLoopBuiltInHookFactory()
    let state = AgentLoopBuiltInHookFactory.State()
    let hooks = factory.makeHooks(
        dependencies: .testValue(),
        state: state
    )

    #expect(hooks.map(\.id) == [
        "stream-projection",
        "memory-bootstrap",
        "tool-audit",
        "failure-classification",
        "reflection-handling",
        "finalization-guard",
        "business-observability"
    ])
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopBuiltInHookFactoryTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/AgentLoopReflectionAndGuardHookTests
```

Expected: FAIL because the dedicated factory and state holder do not exist yet.

**Step 3: Write the minimal test helpers**

- Add a lightweight `testValue()` dependency constructor for the future builder.
- Add any helper doubles needed to construct a factory without invoking real runtime side effects.

**Step 4: Run tests again**

Expected: still FAIL, but now only because the factory implementation is missing.

**Step 5: Commit**

```bash
git add agentGuiTests/AgentLoopBuiltInHookFactoryTests.swift agentGuiTests/AgentLoopMemoryBootstrapHookTests.swift agentGuiTests/AgentLoopToolAuditHookTests.swift agentGuiTests/AgentLoopReflectionAndGuardHookTests.swift
git commit -m "test: characterize built-in agent loop hook factory"
```

### Task 2: Introduce an explicit built-in hook builder and state holder

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`

**Step 1: Write the failing implementation skeleton**

Create the new file with three core types:

- `AgentLoopBuiltInHookFactory`
- `AgentLoopBuiltInHookFactory.Dependencies`
- `AgentLoopBuiltInHookFactory.State`

Suggested shape:

```swift
import Foundation
import SwiftAnthropic
import SwiftData

struct AgentLoopBuiltInHookFactory {
    final class State {
        var lastRound: AgentRound?
        var memoryRuntimeProfiles: [String] = []
        var memoryRuntimeLayers: [String] = []
        var memoryRuntimeWarnings: [String] = []
        var memoryRuntimeSnapshotID: String?
    }

    struct Dependencies {
        let claudeService: ClaudeService
        let service: any AnthropicService
        let modelId: String
        let settings: AppSettings
        let session: Session?
        let sessionId: String
        let modelContext: ModelContext
        let parentMessage: Message?
        let toolExecutionContext: ToolContext
        let bootstrapMessagesSnapshot: [MessageParameter.Message]
        let businessLogSink: BusinessLogSink?
        let pendingToolID: (AgentLoopHookContext) -> String
        let roundForToolContext: (AgentLoopHookContext, AgentRound?) -> AgentRound?
    }

    func makeHooks(
        dependencies: Dependencies,
        state: State
    ) -> [AgentLoopHook] {
        []
    }
}
```

**Step 2: Run tests to verify they fail**

Run the same command from Task 1.

Expected: FAIL because `makeHooks(...)` is still empty.

**Step 3: Implement the minimal builder body**

Move the current hook assembly logic from `runCoreAgentLoop(...)` into `makeHooks(...)`, but keep behavior unchanged.

Rules:

- `MemoryBootstrapHook` writes memory metadata into `state`
- `ToolAuditHook` reads memory metadata and `state.lastRound`
- `ReflectionHandlingHook` reads `state.lastRound` and writes reflection data to it
- `FinalizationGuardHook` and `BusinessObservabilityHook` remain stateless builder outputs

**Step 4: Run tests to verify they pass**

Run the same command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/AgentLoopBuiltInHookFactory.swift
git commit -m "refactor: add built-in agent loop hook factory"
```

### Task 3: Replace the nested local factory in runCoreAgentLoop

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`

**Step 1: Write the failing refactor target**

Refactor `runCoreAgentLoop(...)` so it creates:

- `let hookState = AgentLoopBuiltInHookFactory.State()`
- `let hookFactory = AgentLoopBuiltInHookFactory()`
- `let hookDependencies = AgentLoopBuiltInHookFactory.Dependencies(...)`

Then remove the nested `makeAgentLoopHooks()` function and replace:

```swift
let hookDispatcher = AgentLoopHookDispatcher(hooks: makeAgentLoopHooks())
```

with:

```swift
let hookDispatcher = AgentLoopHookDispatcher(
    hooks: hookFactory.makeHooks(dependencies: hookDependencies, state: hookState)
)
```

Also update direct local state references:

- `lastRound = round` becomes `hookState.lastRound = round`
- reads of `memoryRuntimeProfiles` etc. move behind `hookState`

**Step 2: Run focused tests to verify the refactor compiles**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopHookDispatcherTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/AgentLoopReflectionAndGuardHookTests
```

Expected: initial FAIL if any direct local state reference remains.

**Step 3: Implement the minimal fixes**

- Remove obsolete locals that moved into `hookState`
- Keep non-hook loop state local to `runCoreAgentLoop(...)`
- Do not move `dispatchHooks(...)`, `emitHook(...)`, or stop-reason branching out of the function yet

**Step 4: Run focused tests to verify they pass**

Run the same command.

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift
git commit -m "refactor: extract built-in hook assembly from core loop"
```

### Task 4: Prove caller paths still behave the same

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/WorkflowBusinessObservabilityTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/StoryMemoryPromptAssemblerTests.swift`

**Step 1: Add or tighten regression assertions**

Ensure the extraction did not alter main-agent, workflow, or story bootstrap behavior.

Add or retain assertions for:

- lifecycle event order remains unchanged
- workflow action projection still works
- story memory bootstrap helper behavior remains unchanged for non-memory tasks

**Step 2: Run tests to verify they pass**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: PASS.

**Step 3: Commit**

```bash
git add agentGuiTests/AgentLoopBusinessObservabilityTests.swift agentGuiTests/WorkflowBusinessObservabilityTests.swift agentGuiTests/StoryMemoryPromptAssemblerTests.swift
git commit -m "test: verify hook factory extraction preserves caller behavior"
```

### Task 5: Run the focused regression suite and tidy the architecture docs if needed

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/docs/technical-spec/2026-03-10-agent-architecture.md`

**Step 1: Run the regression suite**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopBuiltInHookFactoryTests \
  -only-testing:agentGuiTests/AgentLoopHookDispatcherTests \
  -only-testing:agentGuiTests/AgentLoopBusinessObservabilityTests \
  -only-testing:agentGuiTests/AgentLoopStreamProjectionHookTests \
  -only-testing:agentGuiTests/AgentLoopMemoryBootstrapHookTests \
  -only-testing:agentGuiTests/AgentLoopToolAuditHookTests \
  -only-testing:agentGuiTests/AgentLoopFailureClassificationHookTests \
  -only-testing:agentGuiTests/AgentLoopReflectionAndGuardHookTests \
  -only-testing:agentGuiTests/WorkflowBusinessObservabilityTests \
  -only-testing:agentGuiTests/StoryMemoryPromptAssemblerTests
```

Expected: PASS.

**Step 2: Update docs only if names changed**

If the final extracted type names differ from the current architecture doc, update the technical doc so it mentions `AgentLoopBuiltInHookFactory` and the explicit per-run state holder.

**Step 3: Commit**

```bash
git add docs/technical-spec/2026-03-10-agent-architecture.md
git commit -m "docs: align architecture doc with hook factory extraction"
```

---

## 5. Design notes for the implementer

### 5.1 Why a state holder instead of dozens of inout parameters

The nested local factory currently works because closures implicitly capture mutable locals. Once extracted, that same behavior should remain explicit and narrow. A single small `State` reference type is the least-complex way to preserve those semantics without exploding the builder API.

### 5.2 Why not make the builder static and pure

Because several built-in hooks are not pure:

- memory bootstrap populates runtime metadata for later tool auditing
- tool audit needs access to current `lastRound`
- reflection needs access to the latest persisted `AgentRound`

Trying to force this into a pure static builder would either duplicate state wiring or move the complexity elsewhere.

### 5.3 What not to refactor in this pass

- do not split `runCoreAgentLoop(...)` into multiple files yet
- do not redesign `AgentLoopHookContext`
- do not introduce a generalized hook plugin registry
- do not change the built-in hook order

This plan only extracts hook assembly and makes captured state explicit.

---

## 6. Completion criteria

This refactor is complete when all of the following are true:

1. `runCoreAgentLoop(...)` no longer contains a nested `makeAgentLoopHooks()` function.
2. Built-in hook assembly lives in a dedicated builder file.
3. Per-run mutable state used by hooks is explicit, not hidden in local closure capture.
4. Focused hook and caller regression tests pass without behavior changes.
5. The architecture doc still matches the shipped structure.

Plan complete and saved to `docs/plans/2026-03-12-agent-loop-hook-factory-extraction-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?