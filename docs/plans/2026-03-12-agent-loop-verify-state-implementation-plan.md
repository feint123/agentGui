# Main Agent Loop Verify State Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Upgrade the main agent loop so `verify` becomes a mandatory state before completion, add a dedicated `verifier` subagent that the main loop invokes via `run_subagent`, route verify failures into `reflection`, and replace the current short Chinese `explorer.description` with a detailed English description.

**Architecture:** Keep the existing explicit loop state machine centered on `AgentLoopContext` and `AgentLoopPhase`. Add one new loop phase, `verifying`, and one new focused collaborator, `AgentLoopVerificationCoordinator`, so verification does not sprawl inside `runCoreAgentLoop(...)`. Reuse the existing `CompletionVerification` persistence path in `SessionTaskStateStore`, extend it to carry verifier assessment fields, and use a dedicated `verifier` subagent definition instead of inventing a workflow-only role path.

**Tech Stack:** Swift 6, SwiftData, Swift Testing, SwiftAnthropic, existing `ClaudeService` extensions, existing `run_subagent` path, existing `verify_completion` tool.

---

## 1. Design constraints

- This plan is scoped to the **main agent loop only**. Do not introduce a workflow runtime dependency.
- `verify_completion` remains the main agent's explicit self-report tool, but it is no longer sufficient by itself to finish the loop.
- The new `verifier` is a **subagent** invoked by the host runtime, not a workflow-only concept.
- Prefer extending existing persisted verification storage over adding a second parallel persistence channel.
- Keep the public entry points intact:
  - `ClaudeService.runAgenticLoop(...)`
  - `ClaudeService.runCoreAgentLoop(...)`
  - `ClaudeService.executeRunSubagentTool(...)`

## 2. Target file set

### New files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`

### Modified files

- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`

---

## 3. Task breakdown

### Task 1: Lock the new verify-state behavior with failing tests

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopExecutionGuardTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`

**Step 1: Write failing state-machine tests**

Add coverage for these cases:

```swift
@Test func finalizationAllowTransitionsIntoVerifyingWhenVerificationIsEnabled() {
    var messages: [MessageParameter.Message] = []
    var loopContext = AgentLoopContext(phase: .finalizing)

    _ = AgentLoopPhaseOutcomeApplier.apply(
        phase: .finalizing,
        finalizationDecision: .allow,
        loopContext: &loopContext,
        messages: &messages,
        accumulatedText: "done",
        accumulatedTextBeforeRound: "done",
        currentRoundText: "",
        assistantObjects: [],
        reflectionEnabled: true,
        verificationEnabled: true
    )

    #expect(loopContext.phase == .verifying)
}
```

```swift
@Test func verificationFailureTransitionsToReflecting() async throws {
    let coordinator = AgentLoopVerificationCoordinator(...)
    let result = try await coordinator.verify(...report: .fixture(passed: false))
    #expect(result == .failedAndShouldReflect)
}
```

**Step 2: Write failing integration coverage for host-driven verifier invocation**

Extend `AgentLoopIntegrationTests` so one test proves the main loop invokes a nested `verifier` subagent after the main model returns `end_turn`, and only then reports success.

Suggested fake stream sequence:

- batch 1: main loop emits final text + `end_turn`
- batch 2: verifier subagent emits verification JSON + `end_turn`

Assert:

- `result.completedSuccessfully == true`
- verifier subagent audit metadata is persisted
- stored verification includes `passed == true`

**Step 3: Write failing toolset coverage for `verifier`**

Extend `ToolsetResolverTests` to assert `verifier` exists and remains read-only:

```swift
@Test func resolverBuildsReadOnlyToolsetForVerifier() throws {
    let role = try #require(WorkflowRoleDefinition.find(named: "verifier"))
    let settings = AppSettings()
    settings.enableTextEditorTool = true

    let result = DefaultToolsetResolver(registry: DefaultToolRegistry()).resolve(
        .init(context: .subagent, role: role, settings: settings)
    )

    #expect(result.toolIDs.contains("str_replace_based_edit_tool"))
    #expect(!result.toolIDs.contains("bash"))
    #expect(!result.toolIDs.contains("run_subagent"))
}
```

**Step 4: Run the focused test set**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/ToolsetResolverTests
```

Expected: FAIL because the `verifying` phase, verifier coordinator, and verifier role do not exist yet.

**Step 5: Commit**

```bash
git add agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift agentGuiTests/AgentLoopIntegrationTests.swift agentGuiTests/ToolsetResolverTests.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift
git commit -m "test: lock main loop verify-state behavior"
```

### Task 2: Extend the persisted verification model and add the `verifying` phase

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/ExecutionPlan.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/AgentLoopPhase.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/SessionTaskStateStore.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ExecutionPlan.swift`

**Step 1: Extend `CompletionVerification` instead of creating a parallel persistence model**

Modify `CompletionVerification` so it can hold both the main agent's self-report and the verifier's assessment.

Suggested shape:

```swift
struct CompletionVerification: Codable {
    var verified: [String]
    var notVerified: [String]
    var conclusion: String?
    var passed: Bool?
    var summary: String?
    var missingEvidence: [String]
    var riskAreas: [String]
    var recommendedNextAction: String?
    var verifierAgent: String?
    var recordedAt: Date
}
```

Rules:

- Keep new fields optional or defaulted so existing saved JSON still decodes.
- Do not break the current `verify_completion` tool path.
- Add brief comments documenting which fields are self-reported claims vs verifier assessment.

**Step 2: Add merge/update helpers to `SessionTaskStateStore`**

Add one method that updates verifier assessment fields without discarding the original `verified` and `notVerified` lists.

Suggested API:

```swift
func updateVerificationAssessment(
    _ update: VerificationAssessmentUpdate,
    for sessionId: String
) throws
```

Where `VerificationAssessmentUpdate` can be a tiny helper struct or tuple-like value kept in the same file.

**Step 3: Add the explicit `verifying` phase and a verification failure trigger**

In `AgentLoopPhase.swift`:

- add `case verifying`
- include it in `shouldContinue`
- include it in `label`
- add `mutating func verificationComplete(passed: Bool)`
- add `FailureTrigger.verificationFailure(detail: String)`

Suggested transition helper:

```swift
mutating func verificationComplete(passed: Bool) {
    phase = passed ? .finalizing : .reflecting
}
```

Also update `FailureTrigger.description` and `actionLabel` so reflection receives a useful summary.

**Step 4: Keep `executeVerifyCompletion(...)` backward compatible**

Do not change the tool schema yet. Only make sure the stored object still writes the claim fields cleanly and preserves any verifier-assessment defaults.

**Step 5: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Models/ExecutionPlan.swift agentGui/Models/AgentLoopPhase.swift agentGui/Services/SessionTaskStateStore.swift agentGui/Services/ClaudeService+ExecutionPlan.swift agentGuiTests/AgentLoopPhaseOutcomeApplierTests.swift agentGuiTests/AgentLoopExecutionGuardTests.swift
git commit -m "feat: add persisted verification assessment and verifying phase"
```

### Task 3: Add the `verifier` subagent and update `explorer.description`

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Models/WorkflowRoleDefinition.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/ToolsetResolverTests.swift`

**Step 1: Add `verifier` to `WorkflowRoleDefinition.all`**

Create a new built-in role next to `reviewer` and `executor`.

Suggested shape:

```swift
static let verifier = WorkflowRoleDefinition(
    name: "verifier",
    displayName: "验证者",
    description: "Evaluates whether the main agent's completion claim is actually supported by evidence, test results, and unresolved risks. Operates in read-only mode and returns a structured verification verdict.",
    systemPrompt: """
    You are a verification specialist working for the host agent loop.

    Rules:
    - Do not edit files.
    - Judge whether the task is actually complete based on the provided claims, evidence, review feedback, and risks.
    - Return JSON only.
    """,
    enableTextEditor: true,
    enableBash: false,
    toolGrants: [
        .init(toolGroupID: .readOnlyEditor, accessMode: .readOnly, allowedContexts: [.subagent])
    ],
    maxTurnsPerActivation: 6,
    maxActivations: 3
)
```

Keep it read-only. No bash. No nested subagent delegation.

**Step 2: Replace the current `explorer.description` text**

Set `description` to exactly this English string:

```text
Investigates the codebase, local documentation, and approved web sources to gather the minimum high-value context needed for downstream agents. Operates in a strictly read-only mode, identifies relevant files and symbols, summarizes findings, highlights unknowns and risk areas, and returns structured exploration output without making code or file changes.
```

Leave the existing `systemPrompt` alone in this task unless a test shows it also needs alignment.

**Step 3: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test -only-testing:agentGuiTests/ToolsetResolverTests
```

Expected: PASS.

**Step 4: Commit**

```bash
git add agentGui/Models/WorkflowRoleDefinition.swift agentGuiTests/ToolsetResolverTests.swift
git commit -m "feat: add verifier subagent and update explorer description"
```

### Task 4: Build `AgentLoopVerificationCoordinator` and wire `runCoreAgentLoop(...)`

**Files:**
- Create: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/AgentLoopVerificationCoordinator.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+AgenticLoop.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+Subagent.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopVerificationCoordinatorTests.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGuiTests/AgentLoopIntegrationTests.swift`

**Step 1: Create a dedicated verification coordinator**

Add a focused collaborator instead of embedding verifier orchestration directly into `runCoreAgentLoop(...)`.

Suggested API:

```swift
struct AgentLoopVerificationOutcome: Equatable {
    let passed: Bool
    let report: CompletionVerification
    let failureTrigger: FailureTrigger?
}

@MainActor
struct AgentLoopVerificationCoordinator {
    let claudeService: ClaudeService
    let service: any AnthropicService
    let modelId: String
    let settings: AppSettings
    let sessionId: String
    let modelContext: ModelContext

    func verify(
        currentAnswer: String,
        executionEvidence: Set<ExecutionEvidenceKind>,
        existingVerification: CompletionVerification?,
        latestFailureTrigger: FailureTrigger?
    ) async throws -> AgentLoopVerificationOutcome
}
```

Responsibilities:

- build a self-contained verifier task string
- create a synthetic subagent `ToolCall` record for observability
- invoke the `verifier` subagent through existing subagent infrastructure
- parse verifier JSON into the extended `CompletionVerification`
- persist the merged verification object
- return `FailureTrigger.verificationFailure(...)` when verification fails

**Step 2: Expose one reusable helper in `ClaudeService+Subagent.swift`**

Refactor the existing subagent code so the coordinator can invoke a named subagent without faking a full tool-dispatch path inline.

Suggested helper:

```swift
func runNamedSubagent(
    name: String,
    task: String,
    toolCallRecord: ToolCall,
    service: any AnthropicService,
    modelId: String,
    settings: AppSettings,
    sessionId: String,
    modelContext: ModelContext
) async throws -> AgentMessage
```

Implement it by reusing the current `WorkflowRoleDefinition.find(named:)` and `runSubagentLoop(...)` path.

**Step 3: Insert the `verifying` branch into `runCoreAgentLoop(...)`**

Keep the current `end_turn -> finalizing` transition. Then change the finalization branch so `allow` no longer means immediate completion when verification is enabled.

Recommended control flow:

```swift
case .finalizing:
    let finalizationDecision = ...
    let phaseOutcome = AgentLoopPhaseOutcomeApplier.apply(
        phase: .finalizing,
        finalizationDecision: finalizationDecision,
        ...,
        reflectionEnabled: settings.enableReflection,
        verificationEnabled: true
    )

case .verifying:
    let verification = try await coordinator.verify(...)
    if verification.passed {
        loopCtx.verificationComplete(passed: true)
    } else {
        loopCtx.pendingFailureTrigger = verification.failureTrigger
        loopCtx.verificationComplete(passed: false)
    }
    continue
```

Rules:

- If the main agent never called `verify_completion`, the verifier should fail with “missing verification record” instead of silently passing.
- If verifier output cannot be parsed, treat it as failed verification and route to reflection.
- Only set `completedSuccessfully` after `verifying` passes and the loop returns to terminal `finalizing`.

**Step 4: Keep reflection behavior aligned with verification failures**

When verification fails:

- set `loopCtx.pendingFailureTrigger = .verificationFailure(detail: report.summary ?? ...)`
- let the existing reflection entry logic take over
- do not append an immediate correction prompt in the verify branch itself

This preserves the current design where reflection owns retry guidance.

**Step 5: Run targeted tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests
```

Expected: PASS.

**Step 6: Commit**

```bash
git add agentGui/Services/AgentLoopVerificationCoordinator.swift agentGui/Services/ClaudeService+AgenticLoop.swift agentGui/Services/ClaudeService+Subagent.swift agentGuiTests/AgentLoopVerificationCoordinatorTests.swift agentGuiTests/AgentLoopIntegrationTests.swift
git commit -m "feat: wire verifier subagent into main agent loop"
```

### Task 5: Update prompts and tool guidance so the main agent feeds the new verify state correctly

**Files:**
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ClaudeService+ToolBuilder.swift`
- Modify: `/Volumes/T7/文稿/Projects/agentGui/agentGui/Services/ACPClientService.swift`

**Step 1: Tighten the `verify_completion` tool description**

Update the tool description so it no longer reads like an optional courtesy step.

Replace the current description with language equivalent to:

```swift
description: """
Record the completion claims that the host verify state will inspect before the task can finish.
Call this before the final answer to state what was actually verified, what remains unverified, and the overall conclusion.
Do not claim tests or execution results unless they were actually observed.
"""
```

Do not change the input schema in this task.

**Step 2: Update the main-agent system prompt in `ACPClientService.swift`**

Revise the guidance around completion so the model knows:

- `verify_completion` must be called before trying to finish a code task
- the host runtime will run an additional verification pass
- unsupported execution claims will trigger a retry or failed verification

Update the existing “Before giving the final response” section rather than appending a second competing rule block.

**Step 3: Run prompt-adjacent regression tests**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/ToolRegistryTests
```

Expected: PASS.

**Step 4: Commit**

```bash
git add agentGui/Services/ClaudeService+ToolBuilder.swift agentGui/Services/ACPClientService.swift
git commit -m "chore: align prompts and tool guidance with verify state"
```

### Task 6: Run the full targeted regression slice and smoke checks

**Files:**
- Modify only if tests expose regressions.

**Step 1: Run the full targeted regression set**

Run:

```bash
xcodebuild -project agentGui.xcodeproj -scheme agentGui -destination 'platform=macOS' test \
  -only-testing:agentGuiTests/AgentLoopPhaseOutcomeApplierTests \
  -only-testing:agentGuiTests/AgentLoopExecutionGuardTests \
  -only-testing:agentGuiTests/AgentLoopIntegrationTests \
  -only-testing:agentGuiTests/AgentLoopVerificationCoordinatorTests \
  -only-testing:agentGuiTests/ToolsetResolverTests \
  -only-testing:agentGuiTests/ToolRegistryTests
```

Expected: PASS.

**Step 2: Run workspace smoke coverage**

Run the existing task:

```text
Quality Smoke
```

Expected: PASS with no new agent-loop regressions.

**Step 3: Commit**

```bash
git add -A
git commit -m "test: validate main agent loop verify-state rollout"
```

---

## 4. Implementation notes

- Prefer the smallest viable persistence change: enrich `CompletionVerification` rather than adding a second stored model and migration.
- Keep `verify_completion` as an agent-authored claim record; let `verifier` be the machine-checked assessment layer.
- Do not bypass `reflection` when verification fails. That recovery path is part of the feature, not an implementation detail.
- If the verifier needs more context, make that explicit in the structured report and let reflection decide whether to call `explorer` or retry execution.
- Add code comments where the host loop transitions from `finalizing` to `verifying`, because that is the least obvious state-machine change.

## 5. Execution handoff

Plan complete and saved to `docs/plans/2026-03-12-agent-loop-verify-state-implementation-plan.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration.

**2. Parallel Session (separate)** - Open a new session with executing-plans, batch execution with checkpoints.

Which approach?