# ACP Session Load Replay Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prevent ACP session restoration from replaying historical messages and tool events into the current live turn while preserving remote session recovery.

**Architecture:** Introduce an ACP external-session phase boundary that separates session attachment from prompt-turn projection. Providers must complete `session/load` or `session/new` before creating the current assistant message, and ACP updates emitted during restore must never be projected into the new turn.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, ACP JSON-RPC runtime

---

### Task 1: Lock The Regression In Tests

**Files:**
- Modify: `agentGuiTests/GitHubCopilotCLIExecutionProviderTests.swift`
- Modify: `agentGuiTests/OpenCodeCLIExecutionProviderTests.swift`

**Step 1: Write the failing tests**

Add one Copilot test and one OpenCode test covering this sequence:
1. A local session is already bound to a remote ACP session.
2. `ensureSession(...remoteSessionID...)` emits replay `session/update` events before returning.
3. `prompt(...)` emits the new live-turn events.
4. Only live-turn events appear in the newly created assistant message and tool calls.

**Step 2: Run tests to verify they fail**

Run:
`xcodebuild test -scheme agentGui -parallel-testing-enabled NO -destination 'platform=macOS,arch=arm64' -only-testing:agentGuiTests/GitHubCopilotCLIExecutionProviderTests -only-testing:agentGuiTests/OpenCodeCLIExecutionProviderTests`

Expected: FAIL because current providers create the pending assistant message before `session/load` completes.

### Task 2: Add ACP Session Phase Routing

**Files:**
- Create: `agentGui/Services/ACP/ACPExternalSessionTurnRouter.swift`
- Modify: `agentGui/Services/ACP/ACPExternalAgentRuntimeClient.swift`

**Step 1: Introduce a small phase model**

Define explicit phases for each local session:
1. `idle`
2. `restoring`
3. `liveTurn`

The router should provide a minimal API to:
1. begin restore
2. finish restore
3. begin live turn
4. finish live turn
5. decide whether an incoming ACP update should be projected into the current turn

**Step 2: Keep the runtime generic**

Do not hardcode Copilot/OpenCode behavior in the runtime client. The router should live in shared ACP infrastructure and be provider-agnostic.

### Task 3: Move Providers To Attach-Then-Turn Flow

**Files:**
- Modify: `agentGui/Services/GitHubCopilot/GitHubCopilotCLIExecutionProvider.swift`
- Modify: `agentGui/Services/OpenCode/OpenCodeCLIExecutionProvider.swift`

**Step 1: Reorder send flow**

Providers must:
1. resolve binding
2. prepare activation
3. create/reuse runtime
4. restore or create remote session
5. persist updated binding
6. only then create the pending assistant message and enter live-turn routing
7. send `session/prompt`

**Step 2: Route updates by phase**

Incoming ACP updates during restore are ignored for current-turn projection.
Incoming ACP updates during live turn keep existing message/tool projection behavior.

**Step 3: Preserve existing behavior**

Keep:
1. transcript fallback when there is no remote session
2. binding persistence and recovery
3. tool reconciliation at turn completion
4. provider-specific model override behavior

### Task 4: Validate And Review

**Files:**
- Validate affected tests and smoke suite

**Step 1: Run focused tests**

Run the two provider suites first, then any ACP runtime tests touched by the refactor.

**Step 2: Run smoke validation**

Run the existing `Quality Smoke` task.

**Step 3: Review diff**

Check that the final design keeps the restore-vs-turn boundary in shared ACP code, not duplicated provider-local conditionals.