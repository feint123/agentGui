# AgenticLoop SwiftData ModelActor Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move AgenticLoop persistence writes off the main actor and converge SwiftData write operations behind `PersistenceCoordinator`, using a `@ModelActor` writer so loop-time inserts and saves no longer happen directly in `ClaudeService+AgenticLoop.swift`.

**Architecture:** Keep `PersistenceCoordinator` as the UI-facing facade for error classification, failure reporting, and dependency injection. Add a dedicated `@ModelActor` write actor owned by the coordinator, and migrate AgenticLoop to send value-based persistence commands into that actor rather than mutating SwiftData `@Model` instances directly. Replace cross-actor `ToolCall` / `AgentRound` model passing with stable identifiers or lightweight handles.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, macOS app with `-default-isolation=MainActor`.

---

## 1. Review summary

### Main findings

- `ClaudeService` is `@MainActor`, and `runCoreAgentLoop(...)` currently performs multiple `modelContext.insert(...)` / `modelContext.save()` calls inline during streaming and tool execution.
- The current `PersistenceCoordinator` in `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift` only wraps `save()` plus failure classification. It does not own write isolation, transaction boundaries, or background persistence.
- `AgentLoopBuiltInHookFactory.State` and `AgentLoopHookContext` currently carry live SwiftData models (`AgentRound`, `ToolCall`). That design is compatible with one main-context write path, but it is the main blocker to adopting `@ModelActor` cleanly.
- The loop already has non-persistence projection seams, especially `AgentLoopStreamProjectionTarget` and hook-driven text/thinking updates. That means persistence can be decoupled from UI projection without losing live updates.

### Root cause to fix

- The issue is not only that `save()` happens on the main actor.
- The deeper issue is that loop orchestration, UI projection, and durable persistence all share the same `ModelContext` and the same live model objects.
- A correct migration must move from “mutate `@Model` instances in place” to “send write intents to a writer actor and re-fetch by identifier inside that actor”.

## 2. Scope and constraints

- Scope this change to AgenticLoop and the persistence primitives it depends on first. Do not try to migrate every existing SwiftData write in the app in one pass.
- Preserve existing user-visible behavior: rounds still appear, tool calls still update, reflection metadata still persists, and persistence failures still surface through `PersistenceCoordinator.lastFailure`.
- Do not pass `@Model` instances across actor boundaries after the migration. Use `UUID` business IDs already present on `ToolCall` and `AgentRound`, plus explicit fetches in the write actor.
- Keep tests on in-memory SwiftData containers.
- Keep `PersistenceCoordinator` injectable in tests; do not hardwire the writer implementation.

## 3. Target design

### 3.1 Coordinator shape

Keep `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift` as the public entry point, but change its responsibility:

- classify and record persistence failures on the main actor
- expose high-level async write APIs for domains such as tool calls, rounds, workflow, and settings
- delegate actual SwiftData mutations to a dedicated writer actor

Create a new file:

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceStoreActor.swift`

Suggested shape:

```swift
import SwiftData

@ModelActor
actor PersistenceStoreActor {
    func perform<T>(_ operation: (ModelContext) throws -> T) throws -> T {
        let result = try operation(modelContext)
        if modelContext.hasChanges {
            try modelContext.save()
        }
        return result
    }
}
```

Then wrap this actor in `PersistenceCoordinator` methods that translate thrown errors into existing `SaveError` and failure records.

### 3.2 Value-based persistence contracts

Add lightweight references instead of passing live models through hooks.

Suggested new value types in `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopHookModels.swift` or a new persistence-facing file:

```swift
struct AgentRoundReference: Equatable, Sendable {
    let id: UUID
}

struct ToolCallReference: Equatable, Sendable {
    let id: UUID
}
```

Update these types accordingly:

- `AgentLoopBuiltInHookFactory.State.lastRound` from `AgentRound?` to `AgentRoundReference?`
- `AgentLoopHookResult.toolCallRecord` from `ToolCall` to `ToolCallReference`
- `AgentLoopHookDispatchResult.toolCallRecord` from `ToolCall?` to `ToolCallReference?`
- `AgentLoopHookContext.toolCallRecord` from `ToolCall?` to `ToolCallReference?`

Avoid storing `AgentRound` inside `metadata`. If a hook needs round identity, add an explicit typed field or typed reference.

### 3.3 AgentLoop write API surface

Instead of exposing raw `ModelContext`, add explicit methods on `PersistenceCoordinator` for the loop path.

Suggested examples:

```swift
func createAgentRound(
    roundIndex: Int,
    parentMessageID: UUID?
) async throws -> AgentRoundReference

func updateAgentRound(
    _ reference: AgentRoundReference,
    mutate: @Sendable (AgentRound) -> Void
) async throws

func createToolCallRecord(
    payload: ToolCallCreationPayload
) async throws -> ToolCallReference

func updateToolCallRecord(
    _ reference: ToolCallReference,
    payload: ToolCallUpdatePayload
) async throws
```

Use DTO payloads for all writes. Do not expose the actor’s `ModelContext` to callers.

## 4. Files affected

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceStoreActor.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPersistenceCoordinatorTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopHookModels.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

## 5. Task breakdown

### Task 1: Characterize the current write boundaries

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPersistenceCoordinatorTests.swift`

**Step 1: Write failing tests**

Cover these cases before changing production code:

- persistence coordinator can delegate a write operation and still record structured failures
- agent loop can persist a round and a tool call without the test directly touching the loop’s `ModelContext`
- tool call updates are addressable by stable identifier rather than live `ToolCall` instance
- reflection updates still persist against the same round record after the round has been created

**Step 2: Run tests to verify the gaps**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PersistenceCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopPersistenceCoordinatorTests
```

Expected: FAIL because the coordinator does not yet own writer-actor methods and hooks still pass live models.

**Step 3: Commit**

```bash
git add agentGuiTests/PersistenceCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/AgentLoopPersistenceCoordinatorTests.swift
git commit -m "test: characterize agent loop persistence migration"
```

### Task 2: Introduce a writer actor behind PersistenceCoordinator

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceStoreActor.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/PersistenceCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`

**Step 1: Create the writer actor**

Back it with the app’s `ModelContainer`, not the caller’s `ModelContext`. The actor should own its own context via `@ModelActor`.

**Step 2: Add coordinator async APIs**

Add an async wrapper pattern such as:

```swift
func performWrite<T>(
    domain: SaveDomain,
    userMessage: String,
    metadata: [String: String] = [:],
    operation: @Sendable @escaping (PersistenceStoreActor) async throws -> T
) async throws -> T
```

This keeps failure classification centralized while moving the actual SQLite-backed transaction off the main actor.

**Step 3: Preserve current save API temporarily**

Keep `save(_ context:domain:userMessage:metadata:)` during the migration so unrelated call sites keep compiling. Mark it as transitional in comments or with a `TODO`.

**Step 4: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/PersistenceCoordinatorTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/PersistenceStoreActor.swift agentGui/Services/PersistenceCoordinator.swift agentGuiTests/PersistenceCoordinatorTests.swift
git commit -m "refactor: add modelactor-backed persistence coordinator"
```

### Task 3: Replace live model references in hook state with stable handles

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopHookModels.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopBuiltInHookFactory.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Introduce references / payloads**

Define typed references and payload structs for:

- round creation
- round reflection update
- round finalization update
- tool call creation
- tool call result update

**Step 2: Update hook contracts**

Change hook factory dependency signatures so they return references, not SwiftData models. For example:

```swift
let createToolCallRecord: (AgentLoopHookContext, State) async throws -> ToolCallReference
let updateToolCallRecord: (AgentLoopHookContext, State) async throws -> Void
```

**Step 3: Remove `AgentRound` from metadata flow**

Replace uses of `metadata["agentRound"] as? AgentRound` with an explicit `currentRoundReference` field or equivalent typed property.

**Step 4: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Models/AgentLoopHookModels.swift agentGui/Services/AgentLoopBuiltInHookFactory.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "refactor: use persistent references in agent loop hooks"
```

### Task 4: Migrate AgenticLoop write points to coordinator-owned async APIs

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopToolExecutionCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/WorkflowAgentRunner.swift`

**Step 1: Inject coordinator into loop path**

Pass `PersistenceCoordinator` into `runAgenticLoop(...)` / `runCoreAgentLoop(...)` and into `AgentLoopToolExecutionCoordinatorBuilder` instead of relying on the caller’s raw `ModelContext` for writes.

**Step 2: Migrate concrete write points**

Replace inline writes in `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift` for these operations:

- final save at the end of `runAgenticLoop(...)`
- round creation (`modelContext.insert(round)`)
- tool call creation in `createToolCallRecord`
- tool call result/status update in `updateToolCallRecord`
- reflection metadata update on the last round
- stop reason and round completion persistence

Each write should become one coordinator call using a DTO payload.

**Step 3: Preserve UI projection separately**

Do not depend on SwiftData object mutation for incremental text/thinking rendering. Continue using `emitHook(...)` and stream projection targets for live UI updates.

**Step 4: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests
```

Expected: PASS.

**Step 5: Commit**

```bash
git add agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/AgentLoopToolExecutionCoordinator.swift agentGui/Services/ClaudeService+Subagent.swift agentGui/Services/WorkflowAgentRunner.swift
git commit -m "refactor: route agent loop persistence through coordinator"
```

### Task 5: Tighten regression coverage and run smoke validation

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/PersistenceCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift`

**Step 1: Add regression tests for failure and ordering behavior**

Cover:

- persistence failure during tool call update still records `PersistenceFailureRecord`
- round and tool call records remain linked correctly after actor-based writes
- repeated updates to the same tool call do not create duplicate records
- the loop still completes successfully when no persistence failure occurs

**Step 2: Run focused tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/PersistenceCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopToolExecutionCoordinatorTests
```

Expected: PASS.

**Step 3: Run workspace smoke**

Run the existing task:

```text
Quality Smoke
```

If needed, also run:

```text
Sample Unit Baseline
```

**Step 4: Commit**

```bash
git add agentGuiTests/PersistenceCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/AgentLoopToolExecutionCoordinatorTests.swift
git commit -m "test: verify modelactor agent loop persistence"
```

## 6. Implementation notes and pitfalls

- Do not try to reuse the main-thread `ModelContext` inside `@ModelActor`. The writer actor must own its own context.
- Do not return SwiftData `@Model` instances from the writer actor to main-actor loop code. Return identifiers or plain DTOs.
- Because the project uses main-actor default isolation, new Swift Testing cases touching these APIs will usually need `@MainActor` at the test type or method level.
- Treat `PersistenceCoordinator.save(_ context:...)` as a compatibility shim until the main loop migration is complete. Remove or reduce it only after AgenticLoop is stable.
- If the UI depends on observing the exact same in-memory model instance, validate merge behavior explicitly. If merge behavior is insufficient, add an explicit refresh/re-fetch step rather than falling back to cross-actor object mutation.

## 7. Recommended execution order

1. Add characterization tests first.
2. Introduce the writer actor and coordinator async wrapper.
3. Change hook contracts from model objects to value references.
4. Migrate AgenticLoop write points.
5. Run targeted tests, then `Quality Smoke`.

## 8. Success criteria

- `ClaudeService+AgenticLoop.swift` no longer calls `modelContext.insert(...)` or `modelContext.save()` directly for loop persistence.
- AgentLoop hook state and dispatch no longer carry live `ToolCall` or `AgentRound` models across persistence boundaries.
- `PersistenceCoordinator` becomes the single entry point for AgenticLoop SwiftData writes.
- Persistence failures still produce structured `PersistenceFailureRecord` entries.
- Existing AgentLoop integration tests pass, and smoke validation passes.
